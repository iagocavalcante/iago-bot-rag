import XCTest
@testable import WhatsAppAutoReply

final class ChatParserTests: XCTestCase {
    var parser: ChatParser!

    override func setUp() {
        super.setUp()
        parser = ChatParser(userName: "Test User")
    }

    func testParseSingleMessage() {
        let content = "[10/03/2024, 18:55:04] Test User: Quer um x tudo ?"
        let messages = parser.parseChat(content)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.sender, "Test User")
        XCTAssertEqual(messages.first?.content, "Quer um x tudo ?")
    }

    func testParseMultipleMessages() {
        let content = """
        [10/03/2024, 18:55:04] Test User: Quer um x tudo ?
        [10/03/2024, 18:55:37] Contact: Tipo se comer tenho q comer a metade da metade kkk
        [10/03/2024, 18:55:50] Test User: aff
        """
        let messages = parser.parseChat(content)

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].sender, "Test User")
        XCTAssertEqual(messages[1].sender, "Contact")
        XCTAssertEqual(messages[2].content, "aff")
    }

    func testSkipsMediaMessages() {
        let content = """
        [10/03/2024, 19:27:08] Contact: ‎<anexado: 00000038-PHOTO-2024-03-10-19-27-08.jpg>
        [10/03/2024, 19:27:15] Contact: 74 pila
        """
        let messages = parser.parseChat(content)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "74 pila")
    }

    func testConvertToMessages() {
        let parsed = [
            ParsedMessage(timestamp: Date(), sender: "Test User", content: "Hello"),
            ParsedMessage(timestamp: Date(), sender: "Contact", content: "Hi")
        ]

        let messages = parser.convertToMessages(parsed: parsed, contactId: 1, contactName: "Contact")

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].sender, .user)
        XCTAssertEqual(messages[1].sender, .contact)
    }
}
