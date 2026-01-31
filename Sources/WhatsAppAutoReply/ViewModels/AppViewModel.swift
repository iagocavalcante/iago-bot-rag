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
    private let accessibilityMonitor = WhatsAppMonitor()
    private let databaseMonitor = WhatsAppDatabaseMonitor()
    private let responseGenerator = ResponseGenerator()
    private let ollamaClient = OllamaClient()

    private var cancellables = Set<AnyCancellable>()

    /// Currently active monitoring method
    private var activeMonitoringMethod: MonitoringMethod = .accessibility

    /// Track group names we've already responded to with trick detection
    /// This prevents responding multiple times to the same renamed group
    /// Persisted to UserDefaults so it survives app restarts
    private var handledTrickNames: Set<String> {
        get {
            let array = UserDefaults.standard.stringArray(forKey: "handled_trick_names") ?? []
            return Set(array)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: "handled_trick_names")
        }
    }

    /// Track when monitoring started to avoid responding to old messages
    private var monitoringStartTime: Date = Date()

    /// Maximum age of messages to respond to (in seconds)
    /// Messages older than this will be ignored
    private let maxMessageAge: TimeInterval = 20 * 60 // 20 minutes

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
        accessibilityMonitor.hasAccessibilityPermission
    }

    var isWhatsAppRunning: Bool {
        accessibilityMonitor.whatsAppRunning
    }

    var isDatabaseAccessible: Bool {
        databaseMonitor.isDatabaseAccessible()
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
        switch activeMonitoringMethod {
        case .accessibility:
            return accessibilityMonitor.debugInfo
        case .database:
            return databaseMonitor.debugInfo
        }
    }

    var isMonitoring: Bool {
        switch activeMonitoringMethod {
        case .accessibility:
            return accessibilityMonitor.isMonitoring
        case .database:
            return databaseMonitor.isMonitoring
        }
    }

    func setupMonitor() {
        // Setup accessibility monitor callbacks
        accessibilityMonitor.onNewMessage = { [weak self] detected in
            Task { @MainActor in
                self?.log("Message detected from '\(detected.contactName)': \(detected.content.prefix(50))...")
                await self?.handleNewMessage(detected)
            }
        }

        accessibilityMonitor.onDebugLog = { [weak self] msg in
            Task { @MainActor in
                self?.log("[AccMonitor] \(msg)")
            }
        }

        // Setup database monitor callbacks
        databaseMonitor.onNewMessage = { [weak self] detected in
            Task { @MainActor in
                self?.log("Message detected from '\(detected.contactName)': \(detected.content.prefix(50))...")
                await self?.handleNewMessage(detected)
            }
        }

        databaseMonitor.onDebugLog = { [weak self] msg in
            Task { @MainActor in
                self?.log("[DBMonitor] \(msg)")
            }
        }

        // Check permissions periodically
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.accessibilityMonitor.checkPermissions()
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
        let selectedMethod = SettingsManager.shared.monitoringMethod

        // Stop the other monitor if method changed
        if selectedMethod != activeMonitoringMethod {
            switch activeMonitoringMethod {
            case .accessibility:
                accessibilityMonitor.stopMonitoring()
            case .database:
                databaseMonitor.stopMonitoring()
            }
            activeMonitoringMethod = selectedMethod
        }

        if hasActiveContacts && !isMonitoring {
            // Reset the monitoring start time when we begin monitoring
            monitoringStartTime = Date()
            // Note: handledTrickNames is now persisted - don't clear it
            // This ensures we never respond twice to the same trick name
            log("Starting \(selectedMethod.displayName) monitoring - messages older than 20 min will be ignored (tracking \(handledTrickNames.count) handled trick names)")

            switch selectedMethod {
            case .accessibility:
                accessibilityMonitor.startMonitoring()
            case .database:
                databaseMonitor.startMonitoring()
            }
        } else if !hasActiveContacts && isMonitoring {
            switch activeMonitoringMethod {
            case .accessibility:
                accessibilityMonitor.stopMonitoring()
            case .database:
                databaseMonitor.stopMonitoring()
            }
        }
    }

    private func handleNewMessage(_ detected: DetectedMessage) async {
        log("Processing message from '\(detected.contactName)'")

        // Check if message was detected within the valid time window
        // Skip messages that are too old (detected before monitoring started or older than maxMessageAge)
        let messageAge = Date().timeIntervalSince(detected.timestamp)
        let timeSinceMonitoringStarted = Date().timeIntervalSince(monitoringStartTime)

        // Grace period: ignore messages detected in the first 5 seconds after monitoring starts
        // This prevents responding to messages that were already visible when we started
        if timeSinceMonitoringStarted < 5 {
            log("Skipping message - monitoring just started (grace period)")
            return
        }

        // Skip messages older than maxMessageAge (20 minutes)
        if messageAge > maxMessageAge {
            log("Skipping old message - detected \(Int(messageAge))s ago (max: \(Int(maxMessageAge))s)")
            return
        }

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
        // Only respond ONCE per unique trick name (not on every message)
        if matchingContact!.isGroup && detected.contactName != contactName {
            // Normalize the detected name for tracking (remove ", Mentioned" suffix etc.)
            let normalizedTrickName = detected.contactName
                .replacingOccurrences(of: ", Mentioned", with: "")
                .replacingOccurrences(of: ", Pinned", with: "")
                .replacingOccurrences(of: ", Muted", with: "")

            // Only respond if we haven't already handled this trick name
            if !handledTrickNames.contains(normalizedTrickName) {
                if let funnyResponse = detectGroupNameTrick(normalizedTrickName) {
                    log("Sneaky group name detected! Responding with humor (first time only)...")
                    handledTrickNames.insert(normalizedTrickName)

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
            } else {
                log("Trick name already handled, skipping: \(normalizedTrickName.prefix(30))...")
            }
        }

        // Check if this is an audio message and try to transcribe it
        var messageContent = detected.content
        if accessibilityMonitor.isAudioMessage(detected.content) {
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
        if accessibilityMonitor.isStickerMessage(detected.content) || accessibilityMonitor.isImageMessage(detected.content) {
            let mediaType = accessibilityMonitor.isStickerMessage(detected.content) ? "Sticker" : "Image"
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

        // Use reply mode if enabled (quotes the original message)
        // Note: Sending messages always uses the accessibility monitor
        if SettingsManager.shared.useReplyMode {
            log("Sending reply with quote (Reply Mode ON)")
            accessibilityMonitor.sendReplyMessage(pending.response, to: pending.contactName)
        } else {
            accessibilityMonitor.sendMessage(pending.response, to: pending.contactName)
        }

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
        let tree = accessibilityMonitor.dumpAccessibilityTree()
        log("=== WhatsApp Tree Dump ===")
        for line in tree.components(separatedBy: "\n").prefix(30) {
            log(line)
        }
    }
}
