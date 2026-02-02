import XCTest
@testable import WhatsAppAutoReply

final class OllamaClientTests: XCTestCase {
    var client: OllamaClient!

    override func setUp() {
        super.setUp()
        client = OllamaClient()
    }

    func testBuildPrompt() {
        let examples = [
            Message(contactId: 1, sender: .contact, content: "Quer pizza?", timestamp: Date()),
            Message(contactId: 1, sender: .user, content: "bora", timestamp: Date()),
            Message(contactId: 1, sender: .contact, content: "Qual sabor?", timestamp: Date()),
            Message(contactId: 1, sender: .user, content: "calabresa", timestamp: Date())
        ]

        let prompt = client.buildPrompt(
            contactName: "Contact",
            examples: examples,
            newMessage: "Tudo bem?",
            userName: "Test User"
        )

        XCTAssertTrue(prompt.contains("Contact: Quer pizza?"))
        XCTAssertTrue(prompt.contains("Test User: bora"))
        XCTAssertTrue(prompt.contains("Contact: Tudo bem?"))
        XCTAssertTrue(prompt.contains("Portuguese"))
    }

    // Integration test - only run if Ollama is available
    func testGenerateResponseIntegration() async throws {
        guard await client.isAvailable() else {
            throw XCTSkip("Ollama not running")
        }

        let response = try await client.generateResponse(prompt: "Say 'test' in one word")
        XCTAssertFalse(response.isEmpty)
    }
}
