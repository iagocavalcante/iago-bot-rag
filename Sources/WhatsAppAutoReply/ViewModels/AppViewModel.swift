import Foundation
import SwiftUI
import Combine

@MainActor
class AppViewModel: ObservableObject {
    @Published var contacts: [Contact] = []
    @Published var isOllamaRunning = false
    @Published var pendingResponses: [String: PendingResponse] = [:]  // Keyed by contact name
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

    private let dbManager: any DatabaseManaging
    private let accessibilityMonitor: any AccessibilityMonitoring
    private let databaseMonitor: any DatabaseMonitoring
    private let responseGenerator: any ResponseGenerating
    private let ollamaClient: any OllamaAvailabilityChecking
    private let groupNameSecurity: GroupNameSecurityService
    private let settings: any SettingsProviding
    private let audioTranscriptionService: any AudioTranscriptionServicing
    private let imageAnalysisService: any ImageAnalysisServicing
    private let chatImportUseCase: any ChatImporting
    private let monitoringCoordinator: any MonitoringCoordinating

    private var cancellables = Set<AnyCancellable>()

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
        monitoringCoordinator.hasAccessibilityPermission
    }

    var isWhatsAppRunning: Bool {
        monitoringCoordinator.isWhatsAppRunning
    }

    var isDatabaseAccessible: Bool {
        monitoringCoordinator.isDatabaseAccessible
    }

    init(
        dbManager: any DatabaseManaging,
        accessibilityMonitor: any AccessibilityMonitoring,
        databaseMonitor: any DatabaseMonitoring,
        responseGenerator: any ResponseGenerating,
        ollamaClient: any OllamaAvailabilityChecking,
        groupNameSecurity: GroupNameSecurityService,
        settings: any SettingsProviding,
        audioTranscriptionService: any AudioTranscriptionServicing,
        imageAnalysisService: any ImageAnalysisServicing,
        chatImportUseCase: any ChatImporting,
        monitoringCoordinator: any MonitoringCoordinating
    ) {
        self.dbManager = dbManager
        self.accessibilityMonitor = accessibilityMonitor
        self.databaseMonitor = databaseMonitor
        self.responseGenerator = responseGenerator
        self.ollamaClient = ollamaClient
        self.groupNameSecurity = groupNameSecurity
        self.settings = settings
        self.audioTranscriptionService = audioTranscriptionService
        self.imageAnalysisService = imageAnalysisService
        self.chatImportUseCase = chatImportUseCase
        self.monitoringCoordinator = monitoringCoordinator

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
        monitoringCoordinator.debugInfo
    }

    var isMonitoring: Bool {
        monitoringCoordinator.isMonitoring
    }

    func setupMonitor() {
        monitoringCoordinator.setup(
            onDetectedMessage: { [weak self] detected in
                Task { @MainActor in
                    self?.log("Message detected from '\(detected.contactName)': \(detected.content.prefix(50))...")
                    await self?.handleNewMessage(detected)
                }
            },
            onDebugLog: { [weak self] message in
                Task { @MainActor in
                    self?.log(message)
                }
            },
            onPeriodicCheck: { [weak self] in
                Task { @MainActor in
                    self?.checkOllama()
                }
            }
        )
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

        switch monitoringCoordinator.updateMonitoringState(hasActiveContacts: hasActiveContacts) {
        case .started(let method):
            log("Starting \(method.displayName) monitoring - messages older than 20 min will be ignored")
        case .stopped:
            log("Monitoring stopped (no active contacts)")
        case .none:
            break
        }
    }

    private func handleNewMessage(_ detected: DetectedMessage) async {
        log("Processing message from '\(detected.contactName)'")

        switch monitoringCoordinator.messageEligibility(
            timestamp: detected.timestamp,
            maxAge: maxMessageAge,
            gracePeriod: 5
        ) {
        case .inGracePeriod:
            log("Skipping message - monitoring just started (grace period)")
            return
        case .tooOld(let age):
            log("Skipping old message - detected \(Int(age))s ago (max: \(Int(maxMessageAge))s)")
            return
        case .eligible:
            break
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

        // SECURITY: Check group name for prompt injection attempts
        // Uses database-backed tracking to detect name changes and repeated attacks
        if matchingContact!.isGroup {
            // Normalize the detected name (remove suffixes like ", Mentioned")
            let normalizedName = detected.contactName
                .replacingOccurrences(of: ", Mentioned", with: "")
                .replacingOccurrences(of: ", Pinned", with: "")
                .replacingOccurrences(of: ", Muted", with: "")

            // Try to get the chat JID from database for accurate tracking
            let chatJID = databaseMonitor.getChatJID(forName: contactName, isGroup: true)
                ?? "group_\(contactName.hashValue)"  // Fallback if database not available

            // Track this group and check for security issues
            let securityAction = groupNameSecurity.trackGroup(
                chatJID: chatJID,
                currentName: normalizedName
            )

            switch securityAction {
            case .blockGroup(let reason):
                log("Group blocked: \(reason)")
                return

            case .cooldown(let remainingSeconds):
                log("Group in cooldown: \(Int(remainingSeconds / 60)) min remaining")
                return

            case .respondWithHumor(_, _, _):
                // Check if we should silently ignore or respond with humor
                if settings.ignoreGroupNameTricks {
                    log("Suspicious group name detected - ignoring (silent mode)")
                    return
                }

                if let funnyResponse = securityAction.getFunnyResponse() {
                    log("Suspicious group name detected! Responding with humor...")

                    pendingResponses[contactName] = PendingResponse(
                        contactName: contactName,
                        incomingMessage: detected.content,
                        response: funnyResponse,
                        timestamp: Date()
                    )

                    try? await Task.sleep(nanoseconds: 5_000_000_000)

                    if pendingResponses[contactName] != nil {
                        sendPendingResponse(for: contactName)
                    }
                    return
                }

            case .respondWithCaution(let warning):
                log("Group name warning: \(warning) - proceeding with caution")
                // Continue but with awareness

            case .allowNormally:
                break // All good, continue normally
            }
        }

        // Check if this is an audio message and try to transcribe it
        var messageContent = detected.content
        if accessibilityMonitor.isAudioMessage(detected.content) {
            log("Audio message detected, attempting transcription...")
            if let transcription = try? await audioTranscriptionService.transcribeRecentAudio() {
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

            if let funnyResponse = try? await imageAnalysisService.analyzeRecentImage() {
                log("\(mediaType) analyzed, sending fun response: \(funnyResponse)")
                // For stickers/images, send the fun response directly
                pendingResponses[contactName] = PendingResponse(
                    contactName: contactName,
                    incomingMessage: detected.content,
                    response: funnyResponse,
                    timestamp: Date()
                )

                // Wait 5 seconds then send if not cancelled
                try? await Task.sleep(nanoseconds: 5_000_000_000)

                if pendingResponses[contactName] != nil {
                    sendPendingResponse(for: contactName)
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
                pendingResponses[contactName] = PendingResponse(
                    contactName: contactName,
                    incomingMessage: detected.content,
                    response: response,
                    timestamp: Date()
                )

                // Wait 5 seconds then send if not cancelled
                try await Task.sleep(nanoseconds: 5_000_000_000)

                if pendingResponses[contactName] != nil {
                    sendPendingResponse(for: contactName)
                }
            } else {
                log("No response generated (check message history)", isError: true)
            }
        } catch {
            log("Failed to generate response: \(error)", isError: true)
        }
    }

    func sendPendingResponse(for contactName: String) {
        guard let pending = pendingResponses[contactName] else { return }

        // Use reply mode if enabled (quotes the original message)
        // Note: Sending messages always uses the accessibility monitor
        if settings.useReplyMode {
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

        pendingResponses.removeValue(forKey: contactName)
    }

    func cancelPendingResponse(for contactName: String) {
        pendingResponses.removeValue(forKey: contactName)
    }

    /// Cancel all pending responses
    func cancelAllPendingResponses() {
        pendingResponses.removeAll()
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

    func importChatExport(url: URL) {
        log("Starting import for: \(url.lastPathComponent)")

        // Extract contact name from original URL for initial UI progress
        let filename = url.deletingPathExtension().lastPathComponent
        let contactName = filename.replacingOccurrences(of: "WhatsApp Chat - ", with: "")
        log("Contact name: \(contactName)")

        importProgress = ImportProgress(contactName: contactName, current: 0, total: 0)

        let logFunc: @Sendable (String, Bool) -> Void = { [weak self] msg, isErr in
            Task { @MainActor in
                self?.log(msg, isError: isErr)
            }
        }
        let importUseCase = chatImportUseCase

        Task.detached {
            do {
                let result = try await importUseCase.importChatExport(
                    url: url,
                    log: logFunc
                ) { current, total in
                    Task { @MainActor [weak self] in
                        self?.importProgress = ImportProgress(contactName: contactName, current: current, total: total)
                    }
                }

                await MainActor.run { [weak self] in
                    self?.importProgress = nil
                    self?.loadContacts()
                    self?.log("Import complete: \(result.messageCount) messages for \(result.contactName)")
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
