import XCTest
@testable import WhatsAppAutoReply

final class ChatImportUseCaseTests: XCTestCase {
    func testImportChatExportCreatesContactAndInsertsMessages() async throws {
        let db = MockImportDatabaseManager()
        let rag = MockImportRAG()
        let settings = MockImportSettings()
        settings.isOpenAIConfigured = false
        settings.useRAG = false

        let parser = MockChatParser()
        parser.parsedMessages = [
            ParsedMessage(timestamp: Date(), sender: "Ana", content: "oi"),
            ParsedMessage(timestamp: Date(), sender: "User", content: "fala")
        ]
        parser.convertedMessages = [
            Message(id: 1, contactId: 10, sender: .contact, content: "oi", timestamp: Date()),
            Message(id: 2, contactId: 10, sender: .user, content: "fala", timestamp: Date())
        ]
        let useCase = ChatImportUseCase(
            dbManager: db,
            ragManager: rag,
            settings: settings,
            parserFactory: { parser }
        )

        let source = FileManager.default.temporaryDirectory.appendingPathComponent("chat-import-\(UUID().uuidString).zip")
        try Data("dummy".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let progressCollector = ProgressCollector()
        let result = try await useCase.importChatExport(
            url: source,
            log: { _, _ in }
        ) { current, total in
            progressCollector.append(current: current, total: total)
        }

        XCTAssertEqual(result.contactName, source.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(result.messageCount, 2)
        XCTAssertEqual(db.insertedMessages.count, 2)
        XCTAssertFalse(progressCollector.values.isEmpty)
        XCTAssertEqual(rag.generateEmbeddingsCalls, 0)
    }

    func testImportChatExportGeneratesEmbeddingsWhenEnabled() async throws {
        let db = MockImportDatabaseManager()
        let rag = MockImportRAG()
        let settings = MockImportSettings()
        settings.isOpenAIConfigured = true
        settings.useRAG = true

        let parser = MockChatParser()
        parser.parsedMessages = [ParsedMessage(timestamp: Date(), sender: "Ana", content: "oi")]
        parser.convertedMessages = [Message(id: 1, contactId: 10, sender: .contact, content: "oi", timestamp: Date())]
        let useCase = ChatImportUseCase(
            dbManager: db,
            ragManager: rag,
            settings: settings,
            parserFactory: { parser }
        )

        let source = FileManager.default.temporaryDirectory.appendingPathComponent("chat-import-\(UUID().uuidString).zip")
        try Data("dummy".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        _ = try await useCase.importChatExport(
            url: source,
            log: { _, _ in },
            progress: { _, _ in }
        )

        XCTAssertEqual(rag.generateEmbeddingsCalls, 1)
    }
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(Int, Int)] = []

    var values: [(Int, Int)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(current: Int, total: Int) {
        lock.lock()
        storage.append((current, total))
        lock.unlock()
    }
}

private final class MockImportSettings: SettingsProviding {
    var monitoringMethod: MonitoringMethod = .accessibility
    var ignoreGroupNameTricks: Bool = true
    var useReplyMode: Bool = false
    var isOpenAIConfigured: Bool = false
    var useRAG: Bool = false
}

private final class MockImportRAG: RAGEmbeddingGenerating {
    private(set) var generateEmbeddingsCalls = 0

    func generateEmbeddings(for contactId: Int64, progress: ((Int, Int) -> Void)?) async throws {
        generateEmbeddingsCalls += 1
    }
}

private final class MockImportDatabaseManager: DatabaseManaging {
    private var storedContact: Contact?
    private(set) var insertedMessages: [Message] = []

    func getAllContacts() throws -> [Contact] { storedContact.map { [$0] } ?? [] }
    func updateContactAutoReply(id: Int64, enabled: Bool) throws {}

    func getContactByName(_ name: String) throws -> Contact? {
        guard let contact = storedContact, contact.name == name else { return nil }
        return contact
    }

    func updateContactIsGroup(id: Int64, isGroup: Bool) throws {
        guard var contact = storedContact, contact.id == id else { return }
        contact.isGroup = isGroup
        storedContact = contact
    }

    func insertContact(_ contact: Contact) throws -> Int64 {
        let stored = Contact(id: 10, name: contact.name, autoReplyEnabled: contact.autoReplyEnabled, isGroup: contact.isGroup)
        storedContact = stored
        return stored.id
    }

    func insertMessages(_ messageList: [Message], batchSize: Int, progress: ((Int, Int) -> Void)?) throws {
        insertedMessages.append(contentsOf: messageList)
        progress?(messageList.count, messageList.count)
    }

    func getMessagesForContact(contactId: Int64, limit: Int) throws -> [Message] {
        []
    }
}

private final class MockChatParser: ChatParsing {
    var parsedMessages: [ParsedMessage] = []
    var convertedMessages: [Message] = []
    var groupChat = false

    func parseTempZipFileWithLog(at tempZip: URL) -> ([ParsedMessage], [String]) {
        (parsedMessages, ["ok"])
    }

    func isGroupChat(messages: [ParsedMessage]) -> Bool {
        groupChat
    }

    func getUniqueSenders(messages: [ParsedMessage]) -> [String] {
        Array(Set(messages.map { $0.sender }))
    }

    func convertToMessages(parsed: [ParsedMessage], contactId: Int64, contactName: String) -> [Message] {
        convertedMessages
    }
}
