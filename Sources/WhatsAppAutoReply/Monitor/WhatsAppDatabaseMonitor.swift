import Foundation
import SQLite3

/// Media information from WhatsApp database
struct MediaInfo {
    let mediaItemId: Int64
    let localPath: String?
    let mediaType: MediaType
    let fileSize: Int64
    let durationSeconds: Double?  // For audio/video
    let mimeType: String?

    enum MediaType: Int {
        case text = 0
        case image = 1
        case audio = 2       // Voice note
        case video = 3
        case contact = 5
        case location = 6
        case link = 7
        case document = 8
        case sticker = 13
        case gif = 14
        case unknown = -1

        var description: String {
            switch self {
            case .text: return "text"
            case .image: return "image"
            case .audio: return "audio"
            case .video: return "video"
            case .contact: return "contact"
            case .location: return "location"
            case .link: return "link"
            case .document: return "document"
            case .sticker: return "sticker"
            case .gif: return "gif"
            case .unknown: return "unknown"
            }
        }

        var isTranscribable: Bool {
            return self == .audio
        }

        var isAnalyzable: Bool {
            return self == .image || self == .sticker || self == .gif
        }
    }

    /// Full path to the media file
    var fullPath: URL? {
        guard let localPath = localPath else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let basePath = home.appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared")
        return basePath.appendingPathComponent(localPath)
    }
}

/// Reply/Quote information from WhatsApp database
struct ReplyInfo {
    let quotedStanzaId: String       // ID of the message being replied to
    let quotedMessageText: String?   // Text of the quoted message
    let quotedSenderJID: String?     // JID of who sent the quoted message
    let quotedIsFromMe: Bool         // Whether the quoted message was from us

    /// Check if this is a reply to one of our messages
    var isReplyToMe: Bool {
        return quotedIsFromMe
    }
}

/// Message from WhatsApp database
struct DatabaseMessage {
    let id: Int64
    let stanzaId: String?            // Unique message ID (for tracking replies)
    let chatName: String
    let chatJID: String
    let text: String
    let isFromMe: Bool
    let timestamp: Date
    let senderName: String?
    let isGroup: Bool
    let mediaInfo: MediaInfo?        // Media attachment info if present
    let messageType: Int             // Raw message type from DB
    let replyInfo: ReplyInfo?        // Info about quoted/replied message

    /// Check if this message has processable media
    var hasMedia: Bool {
        return mediaInfo != nil
    }

    /// Check if this is a reply to another message
    var isReply: Bool {
        return replyInfo != nil
    }

    /// Check if this is a reply to one of our messages
    var isReplyToMyMessage: Bool {
        return replyInfo?.isReplyToMe ?? false
    }

    /// Check if this is an audio message that can be transcribed
    var isAudioMessage: Bool {
        return mediaInfo?.mediaType == .audio
    }

    /// Check if this is an image/sticker that can be analyzed
    var isImageMessage: Bool {
        guard let media = mediaInfo else { return false }
        return media.mediaType.isAnalyzable
    }
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

    // MARK: - Schema Detection

    /// Cache for detected schema features
    private var schemaChecked = false
    private var hasStanzaId = false
    private var hasParentStanzaId = false
    private var hasFromJid = false

    /// Check what columns exist in ZWAMESSAGE table
    private func detectSchema() {
        guard !schemaChecked, let db = db else { return }

        // Query table info to see what columns exist
        let query = "PRAGMA table_info(ZWAMESSAGE)"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            debugLog("Could not query table schema")
            schemaChecked = true
            return
        }

        defer { sqlite3_finalize(statement) }

        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(statement, 1) { // Column name is at index 1
                columns.insert(String(cString: ptr).uppercased())
            }
        }

        hasStanzaId = columns.contains("ZSTANZAID")
        hasParentStanzaId = columns.contains("ZPARENTSTANZAID")
        hasFromJid = columns.contains("ZFROMJID")

        debugLog("Schema detected - ZSTANZAID: \(hasStanzaId), ZPARENTSTANZAID: \(hasParentStanzaId), ZFROMJID: \(hasFromJid)")
        schemaChecked = true
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

            // Log with reply context if present
            if let reply = msg.replyInfo {
                if reply.isReplyToMe {
                    debugLog("REPLY TO MY MESSAGE from '\(msg.chatName)': '\(msg.text.prefix(40))...' (replying to: '\(reply.quotedMessageText?.prefix(20) ?? "?")')")
                } else {
                    debugLog("NEW MESSAGE from '\(msg.chatName)': '\(msg.text.prefix(40))...' (reply to other)")
                }
            } else {
                debugLog("NEW MESSAGE from '\(msg.chatName)': '\(msg.text.prefix(40))...'")
            }

            // Include reply context in the detected message content
            var contentWithContext = msg.text

            // For media-only messages (empty text), add a descriptive placeholder
            // This allows downstream handlers to detect media type
            if contentWithContext.isEmpty, let media = msg.mediaInfo {
                switch media.mediaType {
                case .sticker:
                    contentWithContext = "[Sticker]"
                case .image:
                    contentWithContext = "[Image]"
                case .gif:
                    contentWithContext = "[GIF]"
                case .audio:
                    contentWithContext = "[Audio]"
                case .video:
                    contentWithContext = "[Video]"
                case .document:
                    contentWithContext = "[Document]"
                default:
                    contentWithContext = "[Media]"
                }
                debugLog("Media-only message detected: \(media.mediaType.description)")
            }

            if let reply = msg.replyInfo, reply.isReplyToMe, let quotedText = reply.quotedMessageText {
                // Prefix with quoted context so the bot knows what they're replying to
                contentWithContext = "[Respondendo à minha mensagem: \"\(quotedText.prefix(100))\"]\n\(contentWithContext)"
            }

            let detected = DetectedMessage(
                contactName: msg.chatName,
                content: contentWithContext,
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

        // Detect schema first to know what columns are available
        detectSchema()

        // Build query dynamically based on available columns
        // Base columns that always exist
        var selectColumns = """
            m.Z_PK,
            cs.ZPARTNERNAME,
            cs.ZCONTACTJID,
            m.ZTEXT,
            m.ZISFROMME,
            m.ZMESSAGEDATE,
            m.ZPUSHNAME,
            cs.ZSESSIONTYPE,
            m.ZMESSAGETYPE,
            mi.Z_PK,
            mi.ZMEDIALOCALPATH,
            mi.ZFILESIZE,
            mi.ZMOVIEDURATION,
            mi.ZVCARDSTRING
            """

        // Add optional columns if they exist
        if hasStanzaId {
            selectColumns = "m.ZSTANZAID,\n" + selectColumns
        }

        var joinClause = """
            FROM ZWAMESSAGE m
            JOIN ZWACHATSESSION cs ON m.ZCHATSESSION = cs.Z_PK
            LEFT JOIN ZWAMEDIAITEM mi ON m.ZMEDIAITEM = mi.Z_PK
            """

        // Add reply-related columns and join if schema supports it
        if hasParentStanzaId && hasStanzaId {
            selectColumns += ",\nm.ZPARENTSTANZAID,\nquoted.ZTEXT,\nquoted.ZISFROMME"
            if hasFromJid {
                selectColumns += ",\nquoted.ZFROMJID"
            }
            joinClause += """

                LEFT JOIN ZWAMESSAGE quoted ON m.ZPARENTSTANZAID = quoted.ZSTANZAID
                    AND m.ZCHATSESSION = quoted.ZCHATSESSION
                """
        }

        let query = """
            SELECT
                \(selectColumns)
            \(joinClause)
            WHERE m.Z_PK > ?
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
            // Dynamic column indices based on schema
            // With ZSTANZAID: 0=ZSTANZAID, 1=Z_PK, 2=ZPARTNERNAME, ...
            // Without ZSTANZAID: 0=Z_PK, 1=ZPARTNERNAME, ...
            var col = 0

            let stanzaId: String?
            if hasStanzaId {
                if let ptr = sqlite3_column_text(statement, Int32(col)) {
                    stanzaId = String(cString: ptr)
                } else {
                    stanzaId = nil
                }
                col += 1
            } else {
                stanzaId = nil
            }

            let id = sqlite3_column_int64(statement, Int32(col))
            col += 1

            let chatName: String
            if let ptr = sqlite3_column_text(statement, Int32(col)) {
                chatName = String(cString: ptr)
            } else {
                chatName = "Unknown"
            }
            col += 1

            let chatJID: String
            if let ptr = sqlite3_column_text(statement, Int32(col)) {
                chatJID = String(cString: ptr)
            } else {
                chatJID = ""
            }
            col += 1

            // Text can be nil for media-only messages
            let text: String
            if let ptr = sqlite3_column_text(statement, Int32(col)) {
                text = String(cString: ptr)
            } else {
                text = "" // Allow empty text for media messages
            }
            col += 1

            let isFromMe = sqlite3_column_int(statement, Int32(col)) == 1
            col += 1

            // Convert Apple's Core Data timestamp (seconds since 2001-01-01)
            let timestamp: Date
            let timestampValue = sqlite3_column_double(statement, Int32(col))
            if timestampValue > 0 {
                // Core Data uses reference date of 2001-01-01
                timestamp = Date(timeIntervalSinceReferenceDate: timestampValue)
            } else {
                timestamp = Date()
            }
            col += 1

            let senderName: String?
            if let ptr = sqlite3_column_text(statement, Int32(col)) {
                senderName = String(cString: ptr)
            } else {
                senderName = nil
            }
            col += 1

            // Session type: 0 = individual, 1 = group
            let sessionType = sqlite3_column_int(statement, Int32(col))
            let isGroup = sessionType == 1
            col += 1

            // Message type (0=text, 1=image, 2=audio, etc.)
            let messageType = Int(sqlite3_column_int(statement, Int32(col)))
            col += 1

            // Parse media info if present
            var mediaInfo: MediaInfo? = nil
            let mediaItemId = sqlite3_column_int64(statement, Int32(col))
            col += 1
            if mediaItemId > 0 {
                let localPath: String?
                if let ptr = sqlite3_column_text(statement, Int32(col)) {
                    localPath = String(cString: ptr)
                } else {
                    localPath = nil
                }
                col += 1

                let fileSize = sqlite3_column_int64(statement, Int32(col))
                col += 1
                let duration = sqlite3_column_double(statement, Int32(col))
                col += 1

                let mimeType: String?
                if let ptr = sqlite3_column_text(statement, Int32(col)) {
                    mimeType = String(cString: ptr)
                } else {
                    mimeType = nil
                }
                col += 1

                mediaInfo = MediaInfo(
                    mediaItemId: mediaItemId,
                    localPath: localPath,
                    mediaType: MediaInfo.MediaType(rawValue: messageType) ?? .unknown,
                    fileSize: fileSize,
                    durationSeconds: duration > 0 ? duration : nil,
                    mimeType: mimeType
                )
            } else {
                col += 4 // Skip media columns
            }

            // Parse reply info if schema supports it and this message is a reply
            var replyInfo: ReplyInfo? = nil
            if hasParentStanzaId && hasStanzaId {
                if let quotedStanzaIdPtr = sqlite3_column_text(statement, Int32(col)) {
                    let quotedStanzaId = String(cString: quotedStanzaIdPtr)
                    col += 1

                    let quotedText: String?
                    if let ptr = sqlite3_column_text(statement, Int32(col)) {
                        quotedText = String(cString: ptr)
                    } else {
                        quotedText = nil
                    }
                    col += 1

                    let quotedIsFromMe = sqlite3_column_int(statement, Int32(col)) == 1
                    col += 1

                    let quotedSenderJID: String?
                    if hasFromJid {
                        if let ptr = sqlite3_column_text(statement, Int32(col)) {
                            quotedSenderJID = String(cString: ptr)
                        } else {
                            quotedSenderJID = nil
                        }
                        col += 1
                    } else {
                        quotedSenderJID = nil
                    }

                    replyInfo = ReplyInfo(
                        quotedStanzaId: quotedStanzaId,
                        quotedMessageText: quotedText,
                        quotedSenderJID: quotedSenderJID,
                        quotedIsFromMe: quotedIsFromMe
                    )
                }
            }

            // Skip messages with no text AND no media (system messages)
            if text.isEmpty && mediaInfo == nil {
                continue
            }

            let message = DatabaseMessage(
                id: id,
                stanzaId: stanzaId,
                chatName: chatName,
                chatJID: chatJID,
                text: text,
                isFromMe: isFromMe,
                timestamp: timestamp,
                senderName: senderName,
                isGroup: isGroup,
                mediaInfo: mediaInfo,
                messageType: messageType,
                replyInfo: replyInfo
            )

            messages.append(message)
        }

        return messages
    }

    // MARK: - Utilities

    /// Get recent messages for a chat (for context)
    /// Includes reply information to understand conversation threads
    func getRecentMessages(forChat chatName: String, limit: Int = 20) -> [DatabaseMessage] {
        guard openDatabase(), let db = db else { return [] }

        // Detect schema first
        detectSchema()

        // Build query dynamically (same logic as fetchNewMessages)
        var selectColumns = """
            m.Z_PK,
            cs.ZPARTNERNAME,
            cs.ZCONTACTJID,
            m.ZTEXT,
            m.ZISFROMME,
            m.ZMESSAGEDATE,
            m.ZPUSHNAME,
            cs.ZSESSIONTYPE,
            m.ZMESSAGETYPE,
            mi.Z_PK,
            mi.ZMEDIALOCALPATH,
            mi.ZFILESIZE,
            mi.ZMOVIEDURATION,
            mi.ZVCARDSTRING
            """

        if hasStanzaId {
            selectColumns = "m.ZSTANZAID,\n" + selectColumns
        }

        var joinClause = """
            FROM ZWAMESSAGE m
            JOIN ZWACHATSESSION cs ON m.ZCHATSESSION = cs.Z_PK
            LEFT JOIN ZWAMEDIAITEM mi ON m.ZMEDIAITEM = mi.Z_PK
            """

        if hasParentStanzaId && hasStanzaId {
            selectColumns += ",\nm.ZPARENTSTANZAID,\nquoted.ZTEXT,\nquoted.ZISFROMME"
            if hasFromJid {
                selectColumns += ",\nquoted.ZFROMJID"
            }
            joinClause += """

                LEFT JOIN ZWAMESSAGE quoted ON m.ZPARENTSTANZAID = quoted.ZSTANZAID
                    AND m.ZCHATSESSION = quoted.ZCHATSESSION
                """
        }

        let query = """
            SELECT
                \(selectColumns)
            \(joinClause)
            WHERE cs.ZPARTNERNAME = ?
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
            // Dynamic column parsing (same as fetchNewMessages)
            var col = 0

            let stanzaId: String?
            if hasStanzaId {
                if let ptr = sqlite3_column_text(statement, Int32(col)) {
                    stanzaId = String(cString: ptr)
                } else {
                    stanzaId = nil
                }
                col += 1
            } else {
                stanzaId = nil
            }

            let id = sqlite3_column_int64(statement, Int32(col))
            col += 1

            let name: String
            if let ptr = sqlite3_column_text(statement, Int32(col)) {
                name = String(cString: ptr)
            } else {
                name = chatName
            }
            col += 1

            let chatJID: String
            if let ptr = sqlite3_column_text(statement, Int32(col)) {
                chatJID = String(cString: ptr)
            } else {
                chatJID = ""
            }
            col += 1

            let text: String
            if let ptr = sqlite3_column_text(statement, Int32(col)) {
                text = String(cString: ptr)
            } else {
                text = ""
            }
            col += 1

            let isFromMe = sqlite3_column_int(statement, Int32(col)) == 1
            col += 1

            let timestamp: Date
            let timestampValue = sqlite3_column_double(statement, Int32(col))
            if timestampValue > 0 {
                timestamp = Date(timeIntervalSinceReferenceDate: timestampValue)
            } else {
                timestamp = Date()
            }
            col += 1

            let senderName: String?
            if let ptr = sqlite3_column_text(statement, Int32(col)) {
                senderName = String(cString: ptr)
            } else {
                senderName = nil
            }
            col += 1

            let sessionType = sqlite3_column_int(statement, Int32(col))
            let isGroup = sessionType == 1
            col += 1

            let messageType = Int(sqlite3_column_int(statement, Int32(col)))
            col += 1

            // Parse media info if present
            var mediaInfo: MediaInfo? = nil
            let mediaItemId = sqlite3_column_int64(statement, Int32(col))
            col += 1
            if mediaItemId > 0 {
                let localPath: String?
                if let ptr = sqlite3_column_text(statement, Int32(col)) {
                    localPath = String(cString: ptr)
                } else {
                    localPath = nil
                }
                col += 1

                let fileSize = sqlite3_column_int64(statement, Int32(col))
                col += 1
                let duration = sqlite3_column_double(statement, Int32(col))
                col += 1

                let mimeType: String?
                if let ptr = sqlite3_column_text(statement, Int32(col)) {
                    mimeType = String(cString: ptr)
                } else {
                    mimeType = nil
                }
                col += 1

                mediaInfo = MediaInfo(
                    mediaItemId: mediaItemId,
                    localPath: localPath,
                    mediaType: MediaInfo.MediaType(rawValue: messageType) ?? .unknown,
                    fileSize: fileSize,
                    durationSeconds: duration > 0 ? duration : nil,
                    mimeType: mimeType
                )
            } else {
                col += 4 // Skip media columns
            }

            // Parse reply info if schema supports it
            var replyInfo: ReplyInfo? = nil
            if hasParentStanzaId && hasStanzaId {
                if let quotedStanzaIdPtr = sqlite3_column_text(statement, Int32(col)) {
                    let quotedStanzaId = String(cString: quotedStanzaIdPtr)
                    col += 1

                    let quotedText: String?
                    if let ptr = sqlite3_column_text(statement, Int32(col)) {
                        quotedText = String(cString: ptr)
                    } else {
                        quotedText = nil
                    }
                    col += 1

                    let quotedIsFromMe = sqlite3_column_int(statement, Int32(col)) == 1
                    col += 1

                    let quotedSenderJID: String?
                    if hasFromJid {
                        if let ptr = sqlite3_column_text(statement, Int32(col)) {
                            quotedSenderJID = String(cString: ptr)
                        } else {
                            quotedSenderJID = nil
                        }
                        col += 1
                    } else {
                        quotedSenderJID = nil
                    }

                    replyInfo = ReplyInfo(
                        quotedStanzaId: quotedStanzaId,
                        quotedMessageText: quotedText,
                        quotedSenderJID: quotedSenderJID,
                        quotedIsFromMe: quotedIsFromMe
                    )
                }
            }

            // Skip messages with no text AND no media
            if text.isEmpty && mediaInfo == nil {
                continue
            }

            messages.append(DatabaseMessage(
                id: id,
                stanzaId: stanzaId,
                chatName: name,
                chatJID: chatJID,
                text: text,
                isFromMe: isFromMe,
                timestamp: timestamp,
                senderName: senderName,
                isGroup: isGroup,
                mediaInfo: mediaInfo,
                messageType: messageType,
                replyInfo: replyInfo
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

    // MARK: - Media Access

    /// Get media info for a specific message ID
    func getMediaInfo(forMessageId messageId: Int64) -> MediaInfo? {
        guard openDatabase(), let db = db else { return nil }

        let query = """
            SELECT
                m.ZMESSAGETYPE,
                mi.Z_PK,
                mi.ZMEDIALOCALPATH,
                mi.ZFILESIZE,
                mi.ZMOVIEDURATION,
                mi.ZVCARDSTRING
            FROM ZWAMESSAGE m
            LEFT JOIN ZWAMEDIAITEM mi ON m.ZMEDIAITEM = mi.Z_PK
            WHERE m.Z_PK = ?
            """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            debugLog("ERROR: Could not prepare media query")
            return nil
        }

        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, messageId)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let messageType = Int(sqlite3_column_int(statement, 0))
        let mediaItemId = sqlite3_column_int64(statement, 1)

        guard mediaItemId > 0 else { return nil }

        let localPath: String?
        if let ptr = sqlite3_column_text(statement, 2) {
            localPath = String(cString: ptr)
        } else {
            localPath = nil
        }

        let fileSize = sqlite3_column_int64(statement, 3)
        let duration = sqlite3_column_double(statement, 4)

        let mimeType: String?
        if let ptr = sqlite3_column_text(statement, 5) {
            mimeType = String(cString: ptr)
        } else {
            mimeType = nil
        }

        return MediaInfo(
            mediaItemId: mediaItemId,
            localPath: localPath,
            mediaType: MediaInfo.MediaType(rawValue: messageType) ?? .unknown,
            fileSize: fileSize,
            durationSeconds: duration > 0 ? duration : nil,
            mimeType: mimeType
        )
    }

    /// Get the most recent audio message from a chat (for transcription)
    /// Returns nil if no audio found or if duration exceeds maxDuration
    func getMostRecentAudio(forChat chatName: String, maxDurationSeconds: Double = 300) -> MediaInfo? {
        guard openDatabase(), let db = db else { return nil }

        let query = """
            SELECT
                m.ZMESSAGETYPE,
                mi.Z_PK,
                mi.ZMEDIALOCALPATH,
                mi.ZFILESIZE,
                mi.ZMOVIEDURATION,
                mi.ZVCARDSTRING
            FROM ZWAMESSAGE m
            JOIN ZWACHATSESSION cs ON m.ZCHATSESSION = cs.Z_PK
            LEFT JOIN ZWAMEDIAITEM mi ON m.ZMEDIAITEM = mi.Z_PK
            WHERE cs.ZPARTNERNAME = ?
                AND m.ZMESSAGETYPE = 2
                AND m.ZISFROMME = 0
                AND mi.Z_PK IS NOT NULL
            ORDER BY m.ZMESSAGEDATE DESC
            LIMIT 1
            """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            debugLog("ERROR: Could not prepare audio query")
            return nil
        }

        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, chatName, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            debugLog("No recent audio found for chat: \(chatName)")
            return nil
        }

        let messageType = Int(sqlite3_column_int(statement, 0))
        let mediaItemId = sqlite3_column_int64(statement, 1)

        guard mediaItemId > 0 else { return nil }

        let localPath: String?
        if let ptr = sqlite3_column_text(statement, 2) {
            localPath = String(cString: ptr)
        } else {
            localPath = nil
        }

        let fileSize = sqlite3_column_int64(statement, 3)
        let duration = sqlite3_column_double(statement, 4)

        // Security: Check duration limit from database
        if duration > 0 && duration > maxDurationSeconds {
            debugLog("Audio too long (\(String(format: "%.0f", duration))s > \(Int(maxDurationSeconds))s max): skipping")
            return nil
        }

        let mimeType: String?
        if let ptr = sqlite3_column_text(statement, 5) {
            mimeType = String(cString: ptr)
        } else {
            mimeType = nil
        }

        let media = MediaInfo(
            mediaItemId: mediaItemId,
            localPath: localPath,
            mediaType: MediaInfo.MediaType(rawValue: messageType) ?? .audio,
            fileSize: fileSize,
            durationSeconds: duration > 0 ? duration : nil,
            mimeType: mimeType
        )

        debugLog("Found audio: \(localPath ?? "unknown") (\(String(format: "%.1f", duration))s)")
        return media
    }

    /// Get the most recent image/sticker from a chat (for analysis)
    func getMostRecentImage(forChat chatName: String) -> MediaInfo? {
        guard openDatabase(), let db = db else { return nil }

        // Message types: 1=image, 13=sticker, 14=gif
        let query = """
            SELECT
                m.ZMESSAGETYPE,
                mi.Z_PK,
                mi.ZMEDIALOCALPATH,
                mi.ZFILESIZE,
                mi.ZMOVIEDURATION,
                mi.ZVCARDSTRING
            FROM ZWAMESSAGE m
            JOIN ZWACHATSESSION cs ON m.ZCHATSESSION = cs.Z_PK
            LEFT JOIN ZWAMEDIAITEM mi ON m.ZMEDIAITEM = mi.Z_PK
            WHERE cs.ZPARTNERNAME = ?
                AND m.ZMESSAGETYPE IN (1, 13, 14)
                AND m.ZISFROMME = 0
                AND mi.Z_PK IS NOT NULL
            ORDER BY m.ZMESSAGEDATE DESC
            LIMIT 1
            """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            debugLog("ERROR: Could not prepare image query")
            return nil
        }

        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, chatName, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            debugLog("No recent image found for chat: \(chatName)")
            return nil
        }

        let messageType = Int(sqlite3_column_int(statement, 0))
        let mediaItemId = sqlite3_column_int64(statement, 1)

        guard mediaItemId > 0 else { return nil }

        let localPath: String?
        if let ptr = sqlite3_column_text(statement, 2) {
            localPath = String(cString: ptr)
        } else {
            localPath = nil
        }

        let fileSize = sqlite3_column_int64(statement, 3)
        let duration = sqlite3_column_double(statement, 4)

        let mimeType: String?
        if let ptr = sqlite3_column_text(statement, 5) {
            mimeType = String(cString: ptr)
        } else {
            mimeType = nil
        }

        let media = MediaInfo(
            mediaItemId: mediaItemId,
            localPath: localPath,
            mediaType: MediaInfo.MediaType(rawValue: messageType) ?? .image,
            fileSize: fileSize,
            durationSeconds: duration > 0 ? duration : nil,
            mimeType: mimeType
        )

        debugLog("Found image: \(localPath ?? "unknown") (type: \(media.mediaType.description))")
        return media
    }

    // MARK: - Group Tracking for Security

    /// Information about a group chat from the database
    struct GroupInfo {
        let chatJID: String
        let currentName: String
        let memberCount: Int?
        let lastMessageDate: Date?
    }

    /// Get all groups from the WhatsApp database
    /// Used for security tracking of group name changes
    func getAllGroups() -> [GroupInfo] {
        guard openDatabase(), let db = db else { return [] }

        // Session type 1 = group
        let query = """
            SELECT
                ZCONTACTJID,
                ZPARTNERNAME,
                ZGROUPMEMBERSCOUNT,
                ZLASTMESSAGEDATE
            FROM ZWACHATSESSION
            WHERE ZSESSIONTYPE = 1
            ORDER BY ZLASTMESSAGEDATE DESC
            """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            debugLog("ERROR: Could not prepare groups query")
            return []
        }

        defer { sqlite3_finalize(statement) }

        var groups: [GroupInfo] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let chatJID: String
            if let ptr = sqlite3_column_text(statement, 0) {
                chatJID = String(cString: ptr)
            } else {
                continue
            }

            let name: String
            if let ptr = sqlite3_column_text(statement, 1) {
                name = String(cString: ptr)
            } else {
                name = "Unknown Group"
            }

            let memberCount = sqlite3_column_int(statement, 2)

            let lastMessageDate: Date?
            let timestampValue = sqlite3_column_double(statement, 3)
            if timestampValue > 0 {
                lastMessageDate = Date(timeIntervalSinceReferenceDate: timestampValue)
            } else {
                lastMessageDate = nil
            }

            groups.append(GroupInfo(
                chatJID: chatJID,
                currentName: name,
                memberCount: memberCount > 0 ? Int(memberCount) : nil,
                lastMessageDate: lastMessageDate
            ))
        }

        debugLog("Found \(groups.count) groups")
        return groups
    }

    /// Get the JID for a chat by name
    /// Returns nil if not found or if it's not a group
    func getChatJID(forName name: String, isGroup: Bool = false) -> String? {
        guard openDatabase(), let db = db else { return nil }

        var query = """
            SELECT ZCONTACTJID
            FROM ZWACHATSESSION
            WHERE ZPARTNERNAME = ?
            """

        if isGroup {
            query += " AND ZSESSIONTYPE = 1"
        }

        query += " LIMIT 1"

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }

        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, name, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW,
              let ptr = sqlite3_column_text(statement, 0) else {
            return nil
        }

        return String(cString: ptr)
    }

    /// Get chat info by JID
    func getChatInfo(byJID jid: String) -> (name: String, isGroup: Bool)? {
        guard openDatabase(), let db = db else { return nil }

        let query = """
            SELECT ZPARTNERNAME, ZSESSIONTYPE
            FROM ZWACHATSESSION
            WHERE ZCONTACTJID = ?
            LIMIT 1
            """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }

        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, jid, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW,
              let ptr = sqlite3_column_text(statement, 0) else {
            return nil
        }

        let name = String(cString: ptr)
        let sessionType = sqlite3_column_int(statement, 1)

        return (name: name, isGroup: sessionType == 1)
    }
}
