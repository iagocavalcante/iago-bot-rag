import Foundation

struct Message: Identifiable, Equatable {
    let id: Int64
    let contactId: Int64
    let sender: Sender
    let content: String
    let timestamp: Date

    enum Sender: String {
        case user
        case contact
    }

    init(id: Int64 = 0, contactId: Int64, sender: Sender, content: String, timestamp: Date) {
        self.id = id
        self.contactId = contactId
        self.sender = sender
        self.content = content
        self.timestamp = timestamp
    }
}
