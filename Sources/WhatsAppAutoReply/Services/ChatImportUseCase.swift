import Foundation

final class ChatImportUseCase: ChatImporting {
    typealias ChatParserFactory = @Sendable () -> any ChatParsing

    private let dbManager: any DatabaseManaging
    private let ragManager: any RAGEmbeddingGenerating
    private let settings: any SettingsProviding
    private let parserFactory: ChatParserFactory

    init(
        dbManager: any DatabaseManaging = DatabaseManager.shared,
        ragManager: any RAGEmbeddingGenerating = RAGManager.shared,
        settings: any SettingsProviding = SettingsManager.shared,
        parserFactory: @escaping ChatParserFactory = { ChatParser() }
    ) {
        self.dbManager = dbManager
        self.ragManager = ragManager
        self.settings = settings
        self.parserFactory = parserFactory
    }

    func importChatExport(
        url: URL,
        log: @escaping @Sendable (String, Bool) -> Void,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> ChatImportResult {
        let parser = parserFactory()
        let filename = url.deletingPathExtension().lastPathComponent
        let contactName = filename.replacingOccurrences(of: "WhatsApp Chat - ", with: "")

        // Copy file to temp while security access is active (quick operation)
        let didStartAccess = url.startAccessingSecurityScopedResource()
        log("Security scoped access: \(didStartAccess)", false)

        let tempDir = FileManager.default.temporaryDirectory
        let tempZip = tempDir.appendingPathComponent(UUID().uuidString + ".zip")

        do {
            try FileManager.default.copyItem(at: url, to: tempZip)
            log("Copied to temp: \(tempZip.path)", false)
        } catch {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
            throw error
        }

        // Release security access immediately - we have the copy now
        if didStartAccess {
            url.stopAccessingSecurityScopedResource()
        }

        defer {
            try? FileManager.default.removeItem(at: tempZip)
        }

        log("Starting parse...", false)

        // Parse on background
        let (parsed, parseLog) = parser.parseTempZipFileWithLog(at: tempZip)

        // Forward parser logs
        for entry in parseLog {
            log(entry, false)
        }

        log("Parsed \(parsed.count) messages", false)

        // Detect if this is a group chat
        let isGroupChat = parser.isGroupChat(messages: parsed)
        if isGroupChat {
            let senders = parser.getUniqueSenders(messages: parsed)
            log("Detected GROUP chat with \(senders.count) participants", false)
        } else {
            log("Detected 1-on-1 chat", false)
        }

        progress(0, parsed.count)

        // Create or get contact
        let contact: Contact
        if let existing = try dbManager.getContactByName(contactName) {
            contact = existing
            log("Found existing contact: \(existing.name)", false)

            if existing.isGroup != isGroupChat {
                try dbManager.updateContactIsGroup(id: existing.id, isGroup: isGroupChat)
                log("Updated group status: \(isGroupChat)", false)
            }
        } else {
            let id = try dbManager.insertContact(Contact(name: contactName, isGroup: isGroupChat))
            contact = Contact(id: id, name: contactName, isGroup: isGroupChat)
            log("Created new contact: \(contactName) (group: \(isGroupChat))", false)
        }

        // Convert messages
        let messages = parser.convertToMessages(
            parsed: parsed,
            contactId: contact.id,
            contactName: contactName
        )
        log("Converted \(messages.count) messages", false)

        try dbManager.insertMessages(messages, batchSize: 500) { current, total in
            progress(current, total)
        }

        if settings.isOpenAIConfigured && settings.useRAG {
            log("Starting RAG embedding generation...", false)
            do {
                try await ragManager.generateEmbeddings(for: contact.id) { current, total in
                    log("Embedding \(current)/\(total)", false)
                }
                log("RAG embeddings complete", false)
            } catch {
                log("RAG embedding failed: \(error)", true)
            }
        }

        return ChatImportResult(contactName: contactName, messageCount: messages.count)
    }
}
