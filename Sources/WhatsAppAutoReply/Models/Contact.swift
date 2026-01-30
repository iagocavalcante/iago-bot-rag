import Foundation

struct Contact: Identifiable, Equatable {
    let id: Int64
    var name: String
    var autoReplyEnabled: Bool
    var isGroup: Bool
    var styleProfile: StyleProfile?
    let createdAt: Date

    init(id: Int64 = 0, name: String, autoReplyEnabled: Bool = false, isGroup: Bool = false, styleProfile: StyleProfile? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.autoReplyEnabled = autoReplyEnabled
        self.isGroup = isGroup
        self.styleProfile = styleProfile
        self.createdAt = createdAt
    }

    static func == (lhs: Contact, rhs: Contact) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.autoReplyEnabled == rhs.autoReplyEnabled &&
        lhs.isGroup == rhs.isGroup
    }
}
