import Foundation
import SwiftUI
import Combine

@MainActor
class AppViewModel: ObservableObject {
    @Published var contacts: [Contact] = []
    @Published var isOllamaRunning = false
    @Published var pendingResponse: PendingResponse?
    @Published var responseLog: [ResponseLogEntry] = []

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
        } catch {
            print("Failed to load contacts: \(error)")
        }
    }

    func checkOllama() {
        Task {
            isOllamaRunning = await ollamaClient.isAvailable()
        }
    }

    func setupMonitor() {
        monitor.onNewMessage = { [weak self] detected in
            Task { @MainActor in
                await self?.handleNewMessage(detected)
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

            // Update local state
            if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
                contacts[index].autoReplyEnabled = newState
            }

            // Start/stop monitoring based on any active contacts
            updateMonitoringState()
        } catch {
            print("Failed to toggle auto-reply: \(error)")
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
        // Check if this contact has auto-reply enabled
        guard contacts.first(where: { $0.name == detected.contactName && $0.autoReplyEnabled }) != nil else {
            return
        }

        do {
            if let response = try await responseGenerator.generateResponse(
                for: detected.contactName,
                message: detected.content
            ) {
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
            }
        } catch {
            print("Failed to generate response: \(error)")
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
        let parser = ChatParser()

        do {
            let (contactName, parsed) = try parser.parseZipFile(at: url)

            // Create or get contact
            var contact: Contact
            if let existing = try dbManager.getContactByName(contactName) {
                contact = existing
            } else {
                let id = try dbManager.insertContact(Contact(name: contactName))
                contact = Contact(id: id, name: contactName)
            }

            // Convert and insert messages
            let messages = parser.convertToMessages(
                parsed: parsed,
                contactId: contact.id,
                contactName: contactName
            )
            try dbManager.insertMessages(messages)

            // Refresh contacts list
            loadContacts()

            print("Imported \(messages.count) messages for \(contactName)")
        } catch {
            print("Import failed: \(error)")
        }
    }

    func requestAccessibilityPermission() {
        _ = AccessibilityHelper.checkAccessibilityPermission()
    }
}
