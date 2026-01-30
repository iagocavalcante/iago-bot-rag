import Foundation
import SQLite

class DatabaseManager {
    static let shared = DatabaseManager()

    private var db: Connection?

    // Tables
    private let contacts = Table("contacts")
    private let messages = Table("messages")

    // Contact columns
    private let contactId = Expression<Int64>("id")
    private let contactName = Expression<String>("name")
    private let autoReplyEnabled = Expression<Bool>("auto_reply_enabled")
    private let isGroup = Expression<Bool>("is_group")
    private let styleProfileJSON = Expression<String?>("style_profile")
    private let contactCreatedAt = Expression<Date>("created_at")

    // Message columns
    private let messageId = Expression<Int64>("id")
    private let messageContactId = Expression<Int64>("contact_id")
    private let messageSender = Expression<String>("sender")
    private let messageContent = Expression<String>("content")
    private let messageTimestamp = Expression<Date>("timestamp")

    init(path: String? = nil) {
        do {
            let dbPath = path ?? getDatabasePath()
            db = try Connection(dbPath)
            createTables()
        } catch {
            print("Database connection error: \(error)")
        }
    }

    private func getDatabasePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("WhatsAppAutoReply")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("data.sqlite").path
    }

    private func createTables() {
        do {
            try db?.run(contacts.create(ifNotExists: true) { t in
                t.column(contactId, primaryKey: .autoincrement)
                t.column(contactName, unique: true)
                t.column(autoReplyEnabled, defaultValue: false)
                t.column(isGroup, defaultValue: false)
                t.column(contactCreatedAt)
            })

            try db?.run(messages.create(ifNotExists: true) { t in
                t.column(messageId, primaryKey: .autoincrement)
                t.column(messageContactId)
                t.column(messageSender)
                t.column(messageContent)
                t.column(messageTimestamp)
                t.foreignKey(messageContactId, references: contacts, contactId)
            })

            // Migration: add is_group column if missing
            migrateIfNeeded()
        } catch {
            print("Table creation error: \(error)")
        }
    }

    private func migrateIfNeeded() {
        // Add is_group column if it doesn't exist
        do {
            _ = try db?.run("ALTER TABLE contacts ADD COLUMN is_group BOOLEAN DEFAULT 0")
            print("Migration: added is_group column")
        } catch {
            // Column likely already exists, ignore
        }

        // Add style_profile column if it doesn't exist
        do {
            _ = try db?.run("ALTER TABLE contacts ADD COLUMN style_profile TEXT")
            print("Migration: added style_profile column")
        } catch {
            // Column likely already exists, ignore
        }
    }

    func updateContactStyleProfile(id: Int64, profile: StyleProfile) throws {
        guard let db = db else { throw DatabaseError.connectionFailed }

        let contact = contacts.filter(contactId == id)
        let json = profile.toJSON()
        try db.run(contact.update(styleProfileJSON <- json))
    }

    // MARK: - Contact Operations

    func insertContact(_ contact: Contact) throws -> Int64 {
        guard let db = db else { throw DatabaseError.connectionFailed }

        let insert = contacts.insert(
            contactName <- contact.name,
            autoReplyEnabled <- contact.autoReplyEnabled,
            isGroup <- contact.isGroup,
            contactCreatedAt <- contact.createdAt
        )
        return try db.run(insert)
    }

    func updateContactIsGroup(id: Int64, isGroup groupFlag: Bool) throws {
        guard let db = db else { throw DatabaseError.connectionFailed }

        let contact = contacts.filter(contactId == id)
        try db.run(contact.update(isGroup <- groupFlag))
    }

    func getAllContacts() throws -> [Contact] {
        guard let db = db else { throw DatabaseError.connectionFailed }

        return try db.prepare(contacts).map { row in
            Contact(
                id: row[contactId],
                name: row[contactName],
                autoReplyEnabled: row[autoReplyEnabled],
                isGroup: (try? row.get(isGroup)) ?? false,
                createdAt: row[contactCreatedAt]
            )
        }
    }

    func updateContactAutoReply(id: Int64, enabled: Bool) throws {
        guard let db = db else { throw DatabaseError.connectionFailed }

        let contact = contacts.filter(contactId == id)
        try db.run(contact.update(autoReplyEnabled <- enabled))
    }

    func getContactByName(_ name: String) throws -> Contact? {
        guard let db = db else { throw DatabaseError.connectionFailed }

        let query = contacts.filter(contactName == name)
        return try db.pluck(query).map { row in
            Contact(
                id: row[contactId],
                name: row[contactName],
                autoReplyEnabled: row[autoReplyEnabled],
                isGroup: (try? row.get(isGroup)) ?? false,
                createdAt: row[contactCreatedAt]
            )
        }
    }

    // MARK: - Message Operations

    func insertMessage(_ message: Message) throws -> Int64 {
        guard let db = db else { throw DatabaseError.connectionFailed }

        let insert = messages.insert(
            messageContactId <- message.contactId,
            messageSender <- message.sender.rawValue,
            messageContent <- message.content,
            messageTimestamp <- message.timestamp
        )
        return try db.run(insert)
    }

    func insertMessages(_ messageList: [Message], batchSize: Int = 500, progress: ((Int, Int) -> Void)? = nil) throws {
        guard let db = db else { throw DatabaseError.connectionFailed }

        // Optimize for bulk inserts
        try db.execute("PRAGMA synchronous = OFF")
        try db.execute("PRAGMA journal_mode = MEMORY")

        let total = messageList.count
        var inserted = 0

        // Insert in batches
        for batch in stride(from: 0, to: messageList.count, by: batchSize) {
            let end = min(batch + batchSize, messageList.count)
            let chunk = Array(messageList[batch..<end])

            try db.transaction {
                for message in chunk {
                    let insert = messages.insert(
                        messageContactId <- message.contactId,
                        messageSender <- message.sender.rawValue,
                        messageContent <- message.content,
                        messageTimestamp <- message.timestamp
                    )
                    _ = try db.run(insert)
                }
            }

            inserted = end
            progress?(inserted, total)
        }

        // Restore safe settings
        try db.execute("PRAGMA synchronous = NORMAL")
        try db.execute("PRAGMA journal_mode = WAL")
    }

    func getMessagesForContact(contactId: Int64, limit: Int = 100) throws -> [Message] {
        guard let db = db else { throw DatabaseError.connectionFailed }

        let query = messages
            .filter(messageContactId == contactId)
            .order(messageTimestamp.desc)
            .limit(limit)

        return try db.prepare(query).map { row in
            Message(
                id: row[messageId],
                contactId: row[messageContactId],
                sender: Message.Sender(rawValue: row[messageSender]) ?? .contact,
                content: row[messageContent],
                timestamp: row[messageTimestamp]
            )
        }.reversed()
    }

    func getMessageCount(contactId: Int64) throws -> Int {
        guard let db = db else { throw DatabaseError.connectionFailed }

        return try db.scalar(messages.filter(messageContactId == contactId).count)
    }

    enum DatabaseError: Error {
        case connectionFailed
    }
}
