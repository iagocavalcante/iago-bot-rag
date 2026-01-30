import Foundation

struct Contact: Identifiable, Equatable {
    let id: Int64
    var name: String
    var autoReplyEnabled: Bool
    var isGroup: Bool
    let createdAt: Date

    init(id: Int64 = 0, name: String, autoReplyEnabled: Bool = false, isGroup: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.autoReplyEnabled = autoReplyEnabled
        self.isGroup = isGroup
        self.createdAt = createdAt
    }
}
