import Foundation
import SwiftUI
import Combine

@MainActor
class AppViewModel: ObservableObject {
    @Published var contacts: [Contact] = []
    @Published var isOllamaRunning = false
    @Published var pendingResponse: PendingResponse?
    @Published var responseLog: [ResponseLogEntry] = []
    @Published var importProgress: ImportProgress?
    @Published var debugLog: [DebugLogEntry] = []

    struct DebugLogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let isError: Bool
    }

    func log(_ message: String, isError: Bool = false) {
        let entry = DebugLogEntry(timestamp: Date(), message: message, isError: isError)
        debugLog.insert(entry, at: 0)
        if debugLog.count > 100 { debugLog.removeLast() }
        print("[\(isError ? "ERROR" : "DEBUG")] \(message)")
    }

    struct ImportProgress {
        let contactName: String
        let current: Int
        let total: Int

        var percent: Double {
            total > 0 ? Double(current) / Double(total) : 0
        }
    }

    private let dbManager = DatabaseManager.shared
    private let monitor = WhatsAppMonitor()
    private let responseGenerator = ResponseGenerator()
    private let ollamaClient = OllamaClient()

    private var cancellables = Set<AnyCancellable>()

    struct PendingResponse {
        let contactName: String
        let incomingMessage: String
        let response: String
        let timestamp: Date
    }

    struct ResponseLogEntry: Identifiable {
        let id = UUID()
        let contactName: String
        let incomingMessage: String
        let response: String
        let timestamp: Date
    }

    var hasAccessibilityPermission: Bool {
        monitor.hasAccessibilityPermission
    }

    var isWhatsAppRunning: Bool {
        monitor.whatsAppRunning
    }

    init() {
        loadContacts()
        setupMonitor()
        checkOllama()
    }

    func loadContacts() {
        do {
            contacts = try dbManager.getAllContacts()
            let enabled = contacts.filter { $0.autoReplyEnabled }.map { $0.name }
            if !enabled.isEmpty {
                log("Loaded \(contacts.count) contacts. Auto-reply ON for: \(enabled.joined(separator: ", "))")
            } else {
                log("Loaded \(contacts.count) contacts. No auto-reply enabled.")
            }
        } catch {
            log("Failed to load contacts: \(error)", isError: true)
        }
    }

    func checkOllama() {
        Task {
            isOllamaRunning = await ollamaClient.isAvailable()
        }
    }

    var monitorDebugInfo: String {
        monitor.debugInfo
    }

    var isMonitoring: Bool {
        monitor.isMonitoring
    }

    func setupMonitor() {
        monitor.onNewMessage = { [weak self] detected in
            Task { @MainActor in
                self?.log("Message detected from '\(detected.contactName)': \(detected.content.prefix(50))...")
                await self?.handleNewMessage(detected)
            }
        }

        monitor.onDebugLog = { [weak self] msg in
            Task { @MainActor in
                self?.log("[Monitor] \(msg)")
            }
        }

        // Check permissions periodically
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.monitor.checkPermissions()
                self?.checkOllama()
            }
        }
    }

    func toggleAutoReply(for contact: Contact) {
        do {
            let newState = !contact.autoReplyEnabled
            try dbManager.updateContactAutoReply(id: contact.id, enabled: newState)
            log("Auto-reply for '\(contact.name)' set to \(newState ? "ON" : "OFF")")

            // Update local state
            if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
                contacts[index].autoReplyEnabled = newState
            }

            // Start/stop monitoring based on any active contacts
            updateMonitoringState()
        } catch {
            log("Failed to toggle auto-reply: \(error)", isError: true)
        }
    }

    private func updateMonitoringState() {
        let hasActiveContacts = contacts.contains { $0.autoReplyEnabled }

        if hasActiveContacts && !monitor.isMonitoring {
            monitor.startMonitoring()
        } else if !hasActiveContacts && monitor.isMonitoring {
            monitor.stopMonitoring()
        }
    }

    private func handleNewMessage(_ detected: DetectedMessage) async {
        log("Processing message from '\(detected.contactName)'")

        // Check if this contact has auto-reply enabled
        // Use fuzzy matching to handle group renames
        let matchingContact = findMatchingContact(detected.contactName)
        if matchingContact == nil {
            log("No contact found matching '\(detected.contactName)'. Available: \(contacts.map { $0.name }.joined(separator: ", "))", isError: true)
            return
        }
        guard matchingContact!.autoReplyEnabled else {
            log("Auto-reply disabled for '\(matchingContact!.name)'")
            return
        }

        // Use the stored contact name for consistency
        let contactName = matchingContact!.name

        // Check if group name itself is trying to trick the bot (sneaky!)
        // Use the DETECTED name, not stored name, to catch renamed groups
        if matchingContact!.isGroup && detected.contactName != contactName {
            if let funnyResponse = detectGroupNameTrick(detected.contactName) {
                log("Sneaky group name detected! Responding with humor...")
                pendingResponse = PendingResponse(
                    contactName: contactName,
                    incomingMessage: detected.content,
                    response: funnyResponse,
                    timestamp: Date()
                )

                try? await Task.sleep(nanoseconds: 5_000_000_000)

                if pendingResponse != nil {
                    sendPendingResponse()
                }
                return
            }
        }

        // Check if this is an audio message and try to transcribe it
        var messageContent = detected.content
        if monitor.isAudioMessage(detected.content) {
            log("Audio message detected, attempting transcription...")
            if let transcription = try? await AudioTranscriptionService.shared.transcribeRecentAudio() {
                log("Audio transcribed: \(transcription.prefix(50))...")
                messageContent = "[Áudio transcrito] \(transcription)"
            } else {
                log("Could not transcribe audio - skipping")
                return // Don't respond if we can't understand the audio
            }
        }

        // Check if this is a sticker or image message and try to analyze it
        if monitor.isStickerMessage(detected.content) || monitor.isImageMessage(detected.content) {
            let mediaType = monitor.isStickerMessage(detected.content) ? "Sticker" : "Image"
            log("\(mediaType) detected, attempting analysis...")

            if let funnyResponse = try? await ImageAnalysisService.shared.analyzeRecentImage() {
                log("\(mediaType) analyzed, sending fun response: \(funnyResponse)")
                // For stickers/images, send the fun response directly
                pendingResponse = PendingResponse(
                    contactName: contactName,
                    incomingMessage: detected.content,
                    response: funnyResponse,
                    timestamp: Date()
                )

                // Wait 5 seconds then send if not cancelled
                try? await Task.sleep(nanoseconds: 5_000_000_000)

                if pendingResponse != nil {
                    sendPendingResponse()
                }
                return
            } else {
                log("Could not analyze \(mediaType) - skipping")
                return // Don't respond if we can't see the image
            }
        }

        log("Generating response for '\(contactName)'...")

        do {
            if let response = try await responseGenerator.generateResponse(
                for: contactName,
                message: messageContent
            ) {
                log("Generated response: \(response.prefix(50))...")
                // Set pending response (user has 5 seconds to cancel)
                pendingResponse = PendingResponse(
                    contactName: contactName,
                    incomingMessage: detected.content,
                    response: response,
                    timestamp: Date()
                )

                // Wait 5 seconds then send if not cancelled
                try await Task.sleep(nanoseconds: 5_000_000_000)

                if pendingResponse != nil {
                    sendPendingResponse()
                }
            } else {
                log("No response generated (check message history)", isError: true)
            }
        } catch {
            log("Failed to generate response: \(error)", isError: true)
        }
    }

    func sendPendingResponse() {
        guard let pending = pendingResponse else { return }

        monitor.sendMessage(pending.response, to: pending.contactName)

        responseLog.insert(ResponseLogEntry(
            contactName: pending.contactName,
            incomingMessage: pending.incomingMessage,
            response: pending.response,
            timestamp: pending.timestamp
        ), at: 0)

        pendingResponse = nil
    }

    func cancelPendingResponse() {
        pendingResponse = nil
    }

    /// Find a matching contact using fuzzy matching
    /// Handles group renames by checking if names start with or contain stored contact names
    private func findMatchingContact(_ detectedName: String) -> Contact? {
        // First try exact match
        if let exact = contacts.first(where: { $0.name == detectedName }) {
            return exact
        }

        // Try prefix match (group renamed to add suffix)
        // e.g., "Group Name, extra stuff" should match "Group Name"
        for contact in contacts {
            if detectedName.hasPrefix(contact.name) {
                log("Fuzzy match: '\(detectedName)' matched to '\(contact.name)' (prefix)")
                return contact
            }
        }

        // Try if detected name is contained in stored name
        // e.g., "Group" should match "Group Name"
        for contact in contacts {
            if contact.name.hasPrefix(detectedName) {
                log("Fuzzy match: '\(detectedName)' matched to '\(contact.name)' (stored prefix)")
                return contact
            }
        }

        // Try contains match for groups with emoji variations
        for contact in contacts where contact.isGroup {
            // Remove emojis and special chars for comparison
            let simplifiedDetected = simplifyForComparison(detectedName)
            let simplifiedContact = simplifyForComparison(contact.name)

            if simplifiedDetected.contains(simplifiedContact) || simplifiedContact.contains(simplifiedDetected) {
                log("Fuzzy match: '\(detectedName)' matched to '\(contact.name)' (simplified)")
                return contact
            }
        }

        return nil
    }

    /// Simplify a string for fuzzy comparison
    private func simplifyForComparison(_ text: String) -> String {
        // Remove emojis, brackets, and extra punctuation
        var simplified = text.lowercased()
        simplified = simplified.replacingOccurrences(of: "[grupo certo]", with: "")
        simplified = simplified.replacingOccurrences(of: "[", with: "")
        simplified = simplified.replacingOccurrences(of: "]", with: "")
        simplified = simplified.components(separatedBy: ",").first ?? simplified
        // Remove emoji characters
        simplified = simplified.unicodeScalars.filter { !$0.properties.isEmojiPresentation }.map { String($0) }.joined()
        simplified = simplified.trimmingCharacters(in: .whitespacesAndNewlines)
        return simplified
    }

    /// Detect if group name is trying to trick the bot (social engineering via rename)
    private func detectGroupNameTrick(_ groupName: String) -> String? {
        let lowerName = groupName.lowercased()

        // Patterns that indicate someone is trying to use the group name to trick the bot
        let trickPatterns = [
            // Portuguese
            "mostre", "mostra", "revele", "revela", "me conta", "me fala",
            "suas variáveis", "suas variaveis", "seu segredo", "seus segredos",
            "sua senha", "seu pix", "seu cpf", "seu cartão", "seu cartao",
            "fale como", "responda como", "ignore as regras", "esquece as regras",
            "finja que", "aja como", "você é", "voce e",
            // English
            "show your", "reveal your", "tell me your", "give me your",
            "your password", "your secrets", "your env", "environment variable",
            "your api key", "your token", "your credentials",
            "act as", "pretend to be", "ignore your rules", "forget your rules",
            "you are now", "new instructions",
            // Prompt injection attempts
            "system prompt", "ignore previous", "disregard", "override",
        ]

        let funnyResponses = [
            "Vixi, renomearam o grupo pra tentar me hackear? Vocês são criativos, hein! 😂🔐",
            "Ahá! Acharam que renomear o grupo ia me enganar? Nice try! 🕵️",
            "Esse nome de grupo tá muito suspeito... vocês tão de sacanagem né? 😏",
            "Hackers de grupo de WhatsApp detected! Alerta vermelho! 🚨😂",
            "Pode mudar o nome do grupo pra 'Me dá sua senha' que também não vai funcionar 🤷‍♂️",
            "A tentativa foi boa, mas meu firewall de piadas está ativo! 🛡️😄",
            "Social engineering via grupo? Vocês merecem um troféu de criatividade! 🏆",
            "Calma lá hackers, eu li o nome do grupo sim 😜 mas não caio nessa!",
        ]

        for pattern in trickPatterns {
            if lowerName.contains(pattern) {
                return funnyResponses.randomElement()!
            }
        }

        return nil
    }

    func importChatExport(url: URL) {
        log("Starting import for: \(url.lastPathComponent)")

        let parser = ChatParser()
        let dbManager = self.dbManager

        // Copy file to temp while security access is active (quick operation)
        let didStartAccess = url.startAccessingSecurityScopedResource()
        log("Security scoped access: \(didStartAccess)")

        let tempDir = FileManager.default.temporaryDirectory
        let tempZip = tempDir.appendingPathComponent(UUID().uuidString + ".zip")

        do {
            try FileManager.default.copyItem(at: url, to: tempZip)
            log("Copied to temp: \(tempZip.path)")
        } catch {
            log("Failed to copy file: \(error)", isError: true)
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            return
        }

        // Release security access immediately - we have the copy now
        if didStartAccess {
            url.stopAccessingSecurityScopedResource()
        }

        // Extract contact name from original URL
        let filename = url.deletingPathExtension().lastPathComponent
        let contactName = filename.replacingOccurrences(of: "WhatsApp Chat - ", with: "")
        log("Contact name: \(contactName)")

        // Show initial progress
        self.importProgress = ImportProgress(contactName: contactName, current: 0, total: 0)

        // Capture self for logging
        let logFunc: @Sendable (String, Bool) -> Void = { [weak self] msg, isErr in
            Task { @MainActor in
                self?.log(msg, isError: isErr)
            }
        }

        // Do all heavy work on background thread
        Task.detached {
            defer {
                try? FileManager.default.removeItem(at: tempZip)
            }

            do {
                logFunc("Starting parse...", false)

                // Parse on background
                let (parsed, parseLog) = parser.parseTempZipFileWithLog(at: tempZip)

                // Forward parser logs
                for entry in parseLog {
                    logFunc(entry, false)
                }

                logFunc("Parsed \(parsed.count) messages", false)

                // Detect if this is a group chat
                let isGroupChat = parser.isGroupChat(messages: parsed)
                if isGroupChat {
                    let senders = parser.getUniqueSenders(messages: parsed)
                    logFunc("Detected GROUP chat with \(senders.count) participants", false)
                } else {
                    logFunc("Detected 1-on-1 chat", false)
                }

                await MainActor.run { [weak self] in
                    self?.importProgress = ImportProgress(contactName: contactName, current: 0, total: parsed.count)
                }

                // Create or get contact
                let contact: Contact
                if let existing = try dbManager.getContactByName(contactName) {
                    contact = existing
                    logFunc("Found existing contact: \(existing.name)", false)
                    // Update isGroup flag if needed
                    if existing.isGroup != isGroupChat {
                        try dbManager.updateContactIsGroup(id: existing.id, isGroup: isGroupChat)
                        logFunc("Updated group status: \(isGroupChat)", false)
                    }
                } else {
                    let id = try dbManager.insertContact(Contact(name: contactName, isGroup: isGroupChat))
                    contact = Contact(id: id, name: contactName, isGroup: isGroupChat)
                    logFunc("Created new contact: \(contactName) (group: \(isGroupChat))", false)
                }

                // Convert messages
                let messages = parser.convertToMessages(
                    parsed: parsed,
                    contactId: contact.id,
                    contactName: contactName
                )
                logFunc("Converted \(messages.count) messages", false)

                // Insert with progress callback
                try dbManager.insertMessages(messages) { current, total in
                    Task { @MainActor [weak self] in
                        self?.importProgress = ImportProgress(contactName: contactName, current: current, total: total)
                    }
                }

                await MainActor.run { [weak self] in
                    self?.importProgress = nil
                    self?.loadContacts()
                    self?.log("Import complete: \(messages.count) messages for \(contactName)")
                }

                // Generate embeddings for RAG if OpenAI is configured
                if SettingsManager.shared.isOpenAIConfigured && SettingsManager.shared.useRAG {
                    logFunc("Starting RAG embedding generation...", false)
                    do {
                        try await RAGManager.shared.generateEmbeddings(for: contact.id) { current, total in
                            logFunc("Embedding \(current)/\(total)", false)
                        }
                        logFunc("RAG embeddings complete", false)
                    } catch {
                        logFunc("RAG embedding failed: \(error)", true)
                    }
                }
            } catch {
                logFunc("Import failed: \(error)", true)
                await MainActor.run { [weak self] in
                    self?.importProgress = nil
                }
            }
        }
    }

    func requestAccessibilityPermission() {
        _ = AccessibilityHelper.checkAccessibilityPermission()
    }

    func dumpWhatsAppTree() {
        let tree = monitor.dumpAccessibilityTree()
        log("=== WhatsApp Tree Dump ===")
        for line in tree.components(separatedBy: "\n").prefix(30) {
            log(line)
        }
    }
}
