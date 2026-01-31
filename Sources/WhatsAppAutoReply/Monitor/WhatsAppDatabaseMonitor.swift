import Foundation
import SQLite3

/// Message from WhatsApp database
struct DatabaseMessage {
    let id: Int64
    let chatName: String
    let chatJID: String
    let text: String
    let isFromMe: Bool
    let timestamp: Date
    let senderName: String?
    let isGroup: Bool
}

/// Monitor WhatsApp messages by reading the local SQLite database
/// More reliable than Accessibility API but requires file system access
class WhatsAppDatabaseMonitor: ObservableObject {
    @Published var isMonitoring = false
    @Published var lastDetectedMessage: DetectedMessage?
    @Published var debugInfo: String = ""

    private var timer: Timer?
    private var lastSeenMessageId: Int64 = 0
    private var db: OpaquePointer?

    var onNewMessage: ((DetectedMessage) -> Void)?
    var onDebugLog: ((String) -> Void)?

    /// Path to WhatsApp's ChatStorage database
    private let databasePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
    }()

    private func debugLog(_ msg: String) {
        debugInfo = msg
        onDebugLog?(msg)
        print("[DBMonitor] \(msg)")
    }

    init() {
        // Don't open DB in init - wait for startMonitoring
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Database Connection

    private func openDatabase() -> Bool {
        guard db == nil else { return true }

        // Open in read-only mode to avoid conflicts with WhatsApp
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(databasePath, &db, flags, nil)

        if result != SQLITE_OK {
            debugLog("ERROR: Could not open WhatsApp database: \(String(cString: sqlite3_errmsg(db)))")
            db = nil
            return false
        }

        debugLog("Database opened successfully")
        return true
    }

    private func closeDatabase() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
            debugLog("Database closed")
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard !isMonitoring else { return }

        debugLog("Starting database monitoring...")

        // Initialize last seen message ID to current max
        if let maxId = getMaxMessageId() {
            lastSeenMessageId = maxId
            debugLog("Starting from message ID: \(maxId)")
        }

        isMonitoring = true
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkForNewMessages()
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        timer?.invalidate()
        timer = nil
        closeDatabase()
        debugLog("Monitoring stopped")
    }

    // MARK: - Message Detection

    private func checkForNewMessages() {
        guard openDatabase() else { return }

        let messages = fetchNewMessages()

        for msg in messages {
            // Skip messages from ourselves
            guard !msg.isFromMe else { continue }

            debugLog("NEW MESSAGE from '\(msg.chatName)': '\(msg.text.prefix(40))...'")

            let detected = DetectedMessage(
                contactName: msg.chatName,
                content: msg.text,
                timestamp: msg.timestamp
            )

            lastDetectedMessage = detected
            onNewMessage?(detected)

            // Update last seen ID
            if msg.id > lastSeenMessageId {
                lastSeenMessageId = msg.id
            }
        }
    }

    private func getMaxMessageId() -> Int64? {
        guard openDatabase() else { return nil }

        let query = "SELECT MAX(Z_PK) FROM ZWAMESSAGE"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            debugLog("ERROR: Could not prepare max ID query")
            return nil
        }

        defer { sqlite3_finalize(statement) }

        if sqlite3_step(statement) == SQLITE_ROW {
            return sqlite3_column_int64(statement, 0)
        }

        return nil
    }

    private func fetchNewMessages() -> [DatabaseMessage] {
        guard let db = db else { return [] }

        // Query for messages newer than last seen ID
        // Join with chat session to get contact/group name
        let query = """
            SELECT
                m.Z_PK,
                cs.ZPARTNERNAME,
                cs.ZCONTACTJID,
                m.ZTEXT,
                m.ZISFROMME,
                m.ZMESSAGEDATE,
                m.ZPUSHNAME,
                cs.ZSESSIONTYPE
            FROM ZWAMESSAGE m
            JOIN ZWACHATSESSION cs ON m.ZCHATSESSION = cs.Z_PK
            WHERE m.Z_PK > ?
                AND m.ZTEXT IS NOT NULL
                AND m.ZTEXT != ''
            ORDER BY m.Z_PK ASC
            LIMIT 50
            """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            debugLog("ERROR: Could not prepare query: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }

        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, lastSeenMessageId)

        var messages: [DatabaseMessage] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)

            let chatName: String
            if let ptr = sqlite3_column_text(statement, 1) {
                chatName = String(cString: ptr)
            } else {
                chatName = "Unknown"
            }

            let chatJID: String
            if let ptr = sqlite3_column_text(statement, 2) {
                chatJID = String(cString: ptr)
            } else {
                chatJID = ""
            }

            let text: String
            if let ptr = sqlite3_column_text(statement, 3) {
                text = String(cString: ptr)
            } else {
                continue // Skip empty messages
            }

            let isFromMe = sqlite3_column_int(statement, 4) == 1

            // Convert Apple's Core Data timestamp (seconds since 2001-01-01)
            let timestamp: Date
            let timestampValue = sqlite3_column_double(statement, 5)
            if timestampValue > 0 {
                // Core Data uses reference date of 2001-01-01
                timestamp = Date(timeIntervalSinceReferenceDate: timestampValue)
            } else {
                timestamp = Date()
            }

            let senderName: String?
            if let ptr = sqlite3_column_text(statement, 6) {
                senderName = String(cString: ptr)
            } else {
                senderName = nil
            }

            // Session type: 0 = individual, 1 = group
            let sessionType = sqlite3_column_int(statement, 7)
            let isGroup = sessionType == 1

            let message = DatabaseMessage(
                id: id,
                chatName: chatName,
                chatJID: chatJID,
                text: text,
                isFromMe: isFromMe,
                timestamp: timestamp,
                senderName: senderName,
                isGroup: isGroup
            )

            messages.append(message)
        }

        return messages
    }

    // MARK: - Utilities

    /// Get recent messages for a chat (for context)
    func getRecentMessages(forChat chatName: String, limit: Int = 20) -> [DatabaseMessage] {
        guard openDatabase(), let db = db else { return [] }

        let query = """
            SELECT
                m.Z_PK,
                cs.ZPARTNERNAME,
                cs.ZCONTACTJID,
                m.ZTEXT,
                m.ZISFROMME,
                m.ZMESSAGEDATE,
                m.ZPUSHNAME,
                cs.ZSESSIONTYPE
            FROM ZWAMESSAGE m
            JOIN ZWACHATSESSION cs ON m.ZCHATSESSION = cs.Z_PK
            WHERE cs.ZPARTNERNAME = ?
                AND m.ZTEXT IS NOT NULL
                AND m.ZTEXT != ''
            ORDER BY m.ZMESSAGEDATE DESC
            LIMIT ?
            """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            debugLog("ERROR: Could not prepare recent messages query")
            return []
        }

        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, chatName, -1, nil)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var messages: [DatabaseMessage] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)

            let name: String
            if let ptr = sqlite3_column_text(statement, 1) {
                name = String(cString: ptr)
            } else {
                name = chatName
            }

            let chatJID: String
            if let ptr = sqlite3_column_text(statement, 2) {
                chatJID = String(cString: ptr)
            } else {
                chatJID = ""
            }

            let text: String
            if let ptr = sqlite3_column_text(statement, 3) {
                text = String(cString: ptr)
            } else {
                continue
            }

            let isFromMe = sqlite3_column_int(statement, 4) == 1

            let timestamp: Date
            let timestampValue = sqlite3_column_double(statement, 5)
            if timestampValue > 0 {
                timestamp = Date(timeIntervalSinceReferenceDate: timestampValue)
            } else {
                timestamp = Date()
            }

            let senderName: String?
            if let ptr = sqlite3_column_text(statement, 6) {
                senderName = String(cString: ptr)
            } else {
                senderName = nil
            }

            let sessionType = sqlite3_column_int(statement, 7)
            let isGroup = sessionType == 1

            messages.append(DatabaseMessage(
                id: id,
                chatName: name,
                chatJID: chatJID,
                text: text,
                isFromMe: isFromMe,
                timestamp: timestamp,
                senderName: senderName,
                isGroup: isGroup
            ))
        }

        return messages.reversed() // Return in chronological order
    }

    /// Get list of all chats with unread messages
    func getUnreadChats() -> [(name: String, unreadCount: Int)] {
        guard openDatabase(), let db = db else { return [] }

        let query = """
            SELECT ZPARTNERNAME, ZUNREADCOUNT
            FROM ZWACHATSESSION
            WHERE ZUNREADCOUNT > 0
            ORDER BY ZLASTMESSAGEDATE DESC
            """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }

        defer { sqlite3_finalize(statement) }

        var chats: [(String, Int)] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(statement, 0) {
                let name = String(cString: ptr)
                let count = Int(sqlite3_column_int(statement, 1))
                chats.append((name, count))
            }
        }

        return chats
    }

    /// Check if database is accessible
    func isDatabaseAccessible() -> Bool {
        return FileManager.default.isReadableFile(atPath: databasePath)
    }
}
