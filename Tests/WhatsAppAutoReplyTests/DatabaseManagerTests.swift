import XCTest
@testable import WhatsAppAutoReply

final class DatabaseManagerTests: XCTestCase {
    var dbManager: DatabaseManager!
    var tempDbPath: String!

    override func setUp() {
        super.setUp()
        tempDbPath = NSTemporaryDirectory() + "test_\(UUID().uuidString).sqlite"
        dbManager = DatabaseManager(path: tempDbPath)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDbPath)
        super.tearDown()
    }

    func testInsertAndGetContact() throws {
        let contact = Contact(name: "Test Contact")
        let id = try dbManager.insertContact(contact)

        XCTAssertGreaterThan(id, 0)

        let contacts = try dbManager.getAllContacts()
        XCTAssertEqual(contacts.count, 1)
        XCTAssertEqual(contacts.first?.name, "Test Contact")
    }

    func testInsertAndGetMessages() throws {
        let contact = Contact(name: "Test Contact")
        let contactId = try dbManager.insertContact(contact)

        let message = Message(
            contactId: contactId,
            sender: .user,
            content: "Hello",
            timestamp: Date()
        )
        let messageId = try dbManager.insertMessage(message)

        XCTAssertGreaterThan(messageId, 0)

        let messages = try dbManager.getMessagesForContact(contactId: contactId)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "Hello")
    }

    func testUpdateAutoReply() throws {
        let contact = Contact(name: "Test Contact")
        let id = try dbManager.insertContact(contact)

        try dbManager.updateContactAutoReply(id: id, enabled: true)

        let updated = try dbManager.getContactByName("Test Contact")
        XCTAssertTrue(updated?.autoReplyEnabled ?? false)
    }
}
