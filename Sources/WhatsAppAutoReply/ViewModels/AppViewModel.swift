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
        let matchingContact = contacts.first(where: { $0.name == detected.contactName })
        if matchingContact == nil {
            log("No contact found matching '\(detected.contactName)'. Available: \(contacts.map { $0.name }.joined(separator: ", "))", isError: true)
            return
        }
        guard matchingContact!.autoReplyEnabled else {
            log("Auto-reply disabled for '\(detected.contactName)'")
            return
        }

        log("Generating response for '\(detected.contactName)'...")

        do {
            if let response = try await responseGenerator.generateResponse(
                for: detected.contactName,
                message: detected.content
            ) {
                log("Generated response: \(response.prefix(50))...")
                // Set pending response (user has 5 seconds to cancel)
                pendingResponse = PendingResponse(
                    contactName: detected.contactName,
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

        monitor.sendMessage(pending.response)

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

                await MainActor.run { [weak self] in
                    self?.importProgress = ImportProgress(contactName: contactName, current: 0, total: parsed.count)
                }

                // Create or get contact
                let contact: Contact
                if let existing = try dbManager.getContactByName(contactName) {
                    contact = existing
                    logFunc("Found existing contact: \(existing.name)", false)
                } else {
                    let id = try dbManager.insertContact(Contact(name: contactName))
                    contact = Contact(id: id, name: contactName)
                    logFunc("Created new contact: \(contactName)", false)
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
