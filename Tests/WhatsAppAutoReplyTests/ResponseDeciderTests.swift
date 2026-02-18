import XCTest
@testable import WhatsAppAutoReply

final class ResponseDeciderTests: XCTestCase {
    func testShouldRespondSkipsAcknowledgment() {
        let decider = ResponseDecider(
            settings: MockDeciderSettings(userName: "Iago"),
            groupContextAnalyzer: MockGroupContextAnalyzer()
        )
        let contact = Contact(id: 1, name: "Ana", autoReplyEnabled: true, isGroup: false)

        let decision = decider.shouldRespond(
            to: "ok",
            from: "Ana",
            contact: contact,
            recentMessages: []
        )

        XCTAssertFalse(decision.shouldRespond)
    }

    func testShouldRespondPrivateQuestion() {
        let decider = ResponseDecider(
            settings: MockDeciderSettings(userName: "Iago"),
            groupContextAnalyzer: MockGroupContextAnalyzer()
        )
        let contact = Contact(id: 1, name: "Ana", autoReplyEnabled: true, isGroup: false)

        let decision = decider.shouldRespond(
            to: "você pode me ajudar?",
            from: "Ana",
            contact: contact,
            recentMessages: []
        )

        XCTAssertTrue(decision.shouldRespond)
    }

    func testShouldParticipateInGroupWhenAnswerableAndRelevant() async {
        let analyzer = MockGroupContextAnalyzer()
        analyzer.isAnswerableQuestionResult = true
        analyzer.shouldParticipateResponses = [(participate: true, reason: "Topic relevance: 80%", score: 0.8)]

        let decider = ResponseDecider(
            settings: MockDeciderSettings(userName: "Iago"),
            groupContextAnalyzer: analyzer
        )

        let decision = await decider.shouldParticipateInGroup(
            groupName: "Dev Group",
            message: "alguém sabe isso?",
            sender: "Carlos",
            contactId: 10,
            recentMessages: []
        )

        XCTAssertTrue(decision.shouldParticipate)
        XCTAssertEqual(analyzer.addMessageCalls, 1)
        switch decision {
        case .participate(_, let confidence):
            if case .high = confidence {
                XCTAssertTrue(true)
            } else {
                XCTFail("Expected high confidence")
            }
        case .skip:
            XCTFail("Expected participation decision")
        }
    }

    func testShouldParticipateInGroupUsesPatternFallback() async {
        let analyzer = MockGroupContextAnalyzer()
        analyzer.isAnswerableQuestionResult = false
        analyzer.shouldParticipateResponses = [(participate: false, reason: "", score: 0.2)]
        analyzer.matchesResponsePatternResult = true

        let decider = ResponseDecider(
            settings: MockDeciderSettings(userName: "Iago"),
            groupContextAnalyzer: analyzer
        )

        let decision = await decider.shouldParticipateInGroup(
            groupName: "Dev Group",
            message: "comentário qualquer",
            sender: "Carlos",
            contactId: 10,
            recentMessages: []
        )

        XCTAssertTrue(decision.shouldParticipate)
        switch decision {
        case .participate(_, let confidence):
            if case .low = confidence {
                XCTAssertTrue(true)
            } else {
                XCTFail("Expected low confidence")
            }
        case .skip:
            XCTFail("Expected participation decision")
        }
    }
}

private final class MockDeciderSettings: ResponseDeciderSettingsProviding {
    let userName: String

    init(userName: String) {
        self.userName = userName
    }
}

private final class MockGroupContextAnalyzer: GroupContextAnalyzing {
    var isAnswerableQuestionResult = false
    var matchesResponsePatternResult = false
    var shouldParticipateResponses: [(participate: Bool, reason: String, score: Float)] = []

    private(set) var addMessageCalls = 0
    private(set) var shouldParticipateCalls = 0

    func addMessage(groupName: String, sender: String, content: String, timestamp: Date) {
        addMessageCalls += 1
    }

    func shouldParticipate(
        in groupName: String,
        contactId: Int64,
        currentMessage: String
    ) async -> (participate: Bool, reason: String, score: Float) {
        shouldParticipateCalls += 1
        if shouldParticipateCalls <= shouldParticipateResponses.count {
            return shouldParticipateResponses[shouldParticipateCalls - 1]
        }
        return (false, "", 0)
    }

    func isAnswerableQuestion(_ message: String) -> Bool {
        isAnswerableQuestionResult
    }

    func matchesResponsePattern(message: String, userMessages: [Message]) -> Bool {
        matchesResponsePatternResult
    }
}
