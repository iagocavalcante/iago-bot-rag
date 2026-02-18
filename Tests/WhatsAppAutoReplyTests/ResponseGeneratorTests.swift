import XCTest
@testable import WhatsAppAutoReply

final class ResponseGeneratorTests: XCTestCase {
    func testGenerateResponseReturnsNilWhenContactMissing() async throws {
        let db = MockDatabaseManager()
        let settings = MockResponseGeneratorSettings()
        let ollama = MockOllamaClient()

        let generator = ResponseGenerator(
            ollamaClient: ollama,
            dbManager: db,
            settings: settings,
            styleAnalyzer: MockStyleAnalyzer(),
            responseDecider: MockResponseDecider(),
            ragManager: MockRAGManager(),
            dailyContextTracker: MockDailyContextTracker()
        )

        let response = try await generator.generateResponse(for: "Unknown", message: "oi")
        XCTAssertNil(response)
    }

    func testGenerateResponseSkipsGroupWithoutMentionWhenTopicParticipationDisabled() async throws {
        let db = MockDatabaseManager()
        let settings = MockResponseGeneratorSettings()
        settings.groupTopicParticipation = false
        settings.smartResponse = false

        let group = Contact(id: 2, name: "Dev Group", autoReplyEnabled: true, isGroup: true)
        db.contactsByName[group.name] = group

        let generator = ResponseGenerator(
            ollamaClient: MockOllamaClient(),
            dbManager: db,
            settings: settings,
            styleAnalyzer: MockStyleAnalyzer(),
            responseDecider: MockResponseDecider(),
            ragManager: MockRAGManager(),
            dailyContextTracker: MockDailyContextTracker()
        )

        let response = try await generator.generateResponse(for: group.name, message: "galera vamos jantar")
        XCTAssertNil(response)
    }

    func testGenerateResponseUsesOllamaPath() async throws {
        let db = MockDatabaseManager()
        let settings = MockResponseGeneratorSettings()
        settings.aiProvider = .ollama
        settings.smartResponse = false
        settings.useRAG = false
        settings.userName = "Iago"

        let contact = Contact(id: 1, name: "Ana", autoReplyEnabled: true, isGroup: false)
        db.contactsByName[contact.name] = contact
        db.messagesByContactId[contact.id] = makeConversationHistory(contactId: contact.id, pairs: 6)

        let ollama = MockOllamaClient(response: "Iago: bora")
        let dailyContext = MockDailyContextTracker()

        let generator = ResponseGenerator(
            ollamaClient: ollama,
            dbManager: db,
            settings: settings,
            styleAnalyzer: MockStyleAnalyzer(),
            responseDecider: MockResponseDecider(),
            ragManager: MockRAGManager(),
            dailyContextTracker: dailyContext
        )

        let response = try await generator.generateResponse(for: contact.name, message: "vamos?")
        XCTAssertEqual(response, "bora")
        XCTAssertNotNil(ollama.lastPrompt)
        XCTAssertEqual(dailyContext.trackedMessages.count, 1)
    }

    private func makeConversationHistory(contactId: Int64, pairs: Int) -> [Message] {
        var messages: [Message] = []
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for i in 0..<pairs {
            let offset = TimeInterval(i * 120)
            messages.append(
                Message(
                    id: Int64(i * 2 + 1),
                    contactId: contactId,
                    sender: .contact,
                    content: "mensagem \(i)?",
                    timestamp: base.addingTimeInterval(offset)
                )
            )
            messages.append(
                Message(
                    id: Int64(i * 2 + 2),
                    contactId: contactId,
                    sender: .user,
                    content: "resposta \(i)",
                    timestamp: base.addingTimeInterval(offset + 30)
                )
            )
        }

        return messages
    }
}

private final class MockResponseGeneratorSettings: ResponseGeneratorSettingsProviding {
    var monitoringMethod: MonitoringMethod = .accessibility
    var ignoreGroupNameTricks: Bool = true
    var useReplyMode: Bool = false
    var isOpenAIConfigured: Bool = false
    var useRAG: Bool = false

    var aiProvider: AIProvider = .ollama
    var openAIKey: String = ""
    var openAIModel: String = "gpt-4o-mini"
    var maritacaKey: String = ""
    var maritacaModel: String = "sabia-3"
    var userName: String = "Iago"
    var smartResponse: Bool = false
    var groupTopicParticipation: Bool = false
    var isMaritacaConfigured: Bool = false
}

private final class MockDatabaseManager: DatabaseManaging {
    var contactsByName: [String: Contact] = [:]
    var messagesByContactId: [Int64: [Message]] = [:]

    func getAllContacts() throws -> [Contact] {
        Array(contactsByName.values)
    }

    func updateContactAutoReply(id: Int64, enabled: Bool) throws {}

    func getContactByName(_ name: String) throws -> Contact? {
        contactsByName[name]
    }

    func updateContactIsGroup(id: Int64, isGroup: Bool) throws {}

    func insertContact(_ contact: Contact) throws -> Int64 {
        contactsByName[contact.name] = contact
        return contact.id
    }

    func insertMessages(_ messageList: [Message], batchSize: Int, progress: ((Int, Int) -> Void)?) throws {}

    func getMessagesForContact(contactId: Int64, limit: Int) throws -> [Message] {
        let values = messagesByContactId[contactId] ?? []
        if values.count <= limit {
            return values
        }
        return Array(values.suffix(limit))
    }
}

private final class MockOllamaClient: OllamaGenerating {
    let response: String
    private(set) var lastPrompt: String?

    init(response: String = "ok") {
        self.response = response
    }

    func generateResponse(prompt: String) async throws -> String {
        lastPrompt = prompt
        return response
    }
}

private final class MockStyleAnalyzer: StyleAnalyzing {
    func analyzeMessages(_ messages: [Message]) -> StyleProfile {
        StyleProfile()
    }
}

private final class MockResponseDecider: ResponseDeciding {
    var shouldRespondResult: ResponseDecision = .respond(confidence: .high, reason: "test")
    var shouldParticipateResult: GroupParticipationDecision = .skip(reason: "test")

    func shouldParticipateInGroup(
        groupName: String,
        message: String,
        sender: String,
        contactId: Int64,
        recentMessages: [Message]
    ) async -> GroupParticipationDecision {
        shouldParticipateResult
    }

    func shouldRespond(
        to message: String,
        from contactName: String,
        contact: Contact,
        recentMessages: [Message]
    ) -> ResponseDecision {
        shouldRespondResult
    }
}

private final class MockRAGManager: RAGContextSearching {
    func findSimilarContext(
        for message: String,
        contactId: Int64,
        limit: Int
    ) async throws -> [(contactMessage: String, userResponse: String, similarity: Float)] {
        []
    }

    func findSimilarThreads(
        for message: String,
        contactId: Int64,
        limit: Int
    ) async throws -> [ConversationThread] {
        []
    }
}

private final class MockDailyContextTracker: DailyContextTracking {
    private(set) var trackedMessages: [(contactId: Int64, content: String, isFromUser: Bool)] = []

    func trackMessage(contactId: Int64, content: String, isFromUser: Bool, timestamp: Date) {
        trackedMessages.append((contactId, content, isFromUser))
    }

    func getContextSummary(for contactId: Int64) -> String? {
        nil
    }
}
