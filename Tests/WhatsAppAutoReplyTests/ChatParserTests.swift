import XCTest
@testable import WhatsAppAutoReply

final class ChatParserTests: XCTestCase {
    var parser: ChatParser!

    override func setUp() {
        super.setUp()
        parser = ChatParser(userName: "Iago Cavalcante")
    }

    func testParseSingleMessage() {
        let content = "[10/03/2024, 18:55:04] Iago Cavalcante: Quer um x tudo ?"
        let messages = parser.parseChat(content)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.sender, "Iago Cavalcante")
        XCTAssertEqual(messages.first?.content, "Quer um x tudo ?")
    }

    func testParseMultipleMessages() {
        let content = """
        [10/03/2024, 18:55:04] Iago Cavalcante: Quer um x tudo ?
        [10/03/2024, 18:55:37] Amor: Tipo se comer tenho q comer a metade da metade kkk
        [10/03/2024, 18:55:50] Iago Cavalcante: aff
        """
        let messages = parser.parseChat(content)

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].sender, "Iago Cavalcante")
        XCTAssertEqual(messages[1].sender, "Amor")
        XCTAssertEqual(messages[2].content, "aff")
    }

    func testSkipsMediaMessages() {
        let content = """
        [10/03/2024, 19:27:08] Amor: ‎<anexado: 00000038-PHOTO-2024-03-10-19-27-08.jpg>
        [10/03/2024, 19:27:15] Amor: 74 pila
        """
        let messages = parser.parseChat(content)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "74 pila")
    }

    func testConvertToMessages() {
        let parsed = [
            ParsedMessage(timestamp: Date(), sender: "Iago Cavalcante", content: "Hello"),
            ParsedMessage(timestamp: Date(), sender: "Amor", content: "Hi")
        ]

        let messages = parser.convertToMessages(parsed: parsed, contactId: 1, contactName: "Amor")

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].sender, .user)
        XCTAssertEqual(messages[1].sender, .contact)
    }
}
