# WhatsApp Auto-Reply Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Swift menu bar app that monitors WhatsApp Desktop and auto-responds using Ollama with per-contact style matching.

**Architecture:** Menu bar app using SwiftUI, Accessibility APIs for WhatsApp interaction, SQLite for contact/message storage, HTTP calls to local Ollama API. Each contact has their own message history for style-matched responses.

**Tech Stack:** Swift 6, SwiftUI, ApplicationServices (Accessibility), SQLite.swift, URLSession

---

## Task 1: Create Swift Package Project Structure

**Files:**
- Create: `Package.swift`
- Create: `Sources/WhatsAppAutoReply/main.swift`
- Create: `Sources/WhatsAppAutoReply/App.swift`

**Step 1: Initialize Swift package**

```bash
swift package init --type executable --name WhatsAppAutoReply
```

**Step 2: Update Package.swift with dependencies**

Replace `Package.swift` with:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhatsAppAutoReply",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.14.1")
    ],
    targets: [
        .executableTarget(
            name: "WhatsAppAutoReply",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift")
            ]
        ),
        .testTarget(
            name: "WhatsAppAutoReplyTests",
            dependencies: ["WhatsAppAutoReply"]
        )
    ]
)
```

**Step 3: Create App.swift for menu bar app**

Create `Sources/WhatsAppAutoReply/App.swift`:

```swift
import SwiftUI

@main
struct WhatsAppAutoReplyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "message.fill", accessibilityDescription: "WhatsApp Auto-Reply")
            button.action = #selector(togglePopover)
        }

        popover = NSPopover()
        popover?.contentSize = NSSize(width: 300, height: 400)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(rootView: MenuBarView())
    }

    @objc func togglePopover() {
        if let button = statusItem?.button {
            if popover?.isShown == true {
                popover?.performClose(nil)
            } else {
                popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
}
```

**Step 4: Create placeholder MenuBarView**

Create `Sources/WhatsAppAutoReply/Views/MenuBarView.swift`:

```swift
import SwiftUI

struct MenuBarView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WhatsApp Auto-Reply")
                .font(.headline)

            Divider()

            Text("No contacts imported")
                .foregroundColor(.secondary)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 280, height: 380)
    }
}
```

**Step 5: Delete auto-generated main.swift if exists**

```bash
rm -f Sources/WhatsAppAutoReply/main.swift
```

**Step 6: Build and verify**

```bash
swift build
```

Expected: Build succeeds

**Step 7: Commit**

```bash
git add Package.swift Sources/
git commit -m "feat: initialize Swift package with menu bar app skeleton"
```

---

## Task 2: Create Database Models and Manager

**Files:**
- Create: `Sources/WhatsAppAutoReply/Models/Contact.swift`
- Create: `Sources/WhatsAppAutoReply/Models/Message.swift`
- Create: `Sources/WhatsAppAutoReply/Database/DatabaseManager.swift`
- Create: `Tests/WhatsAppAutoReplyTests/DatabaseManagerTests.swift`

**Step 1: Create Contact model**

Create `Sources/WhatsAppAutoReply/Models/Contact.swift`:

```swift
import Foundation

struct Contact: Identifiable, Equatable {
    let id: Int64
    var name: String
    var autoReplyEnabled: Bool
    let createdAt: Date

    init(id: Int64 = 0, name: String, autoReplyEnabled: Bool = false, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.autoReplyEnabled = autoReplyEnabled
        self.createdAt = createdAt
    }
}
```

**Step 2: Create Message model**

Create `Sources/WhatsAppAutoReply/Models/Message.swift`:

```swift
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
```

**Step 3: Create DatabaseManager**

Create `Sources/WhatsAppAutoReply/Database/DatabaseManager.swift`:

```swift
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
        } catch {
            print("Table creation error: \(error)")
        }
    }

    // MARK: - Contact Operations

    func insertContact(_ contact: Contact) throws -> Int64 {
        guard let db = db else { throw DatabaseError.connectionFailed }

        let insert = contacts.insert(
            contactName <- contact.name,
            autoReplyEnabled <- contact.autoReplyEnabled,
            contactCreatedAt <- contact.createdAt
        )
        return try db.run(insert)
    }

    func getAllContacts() throws -> [Contact] {
        guard let db = db else { throw DatabaseError.connectionFailed }

        return try db.prepare(contacts).map { row in
            Contact(
                id: row[contactId],
                name: row[contactName],
                autoReplyEnabled: row[autoReplyEnabled],
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

    func insertMessages(_ messageList: [Message]) throws {
        guard let db = db else { throw DatabaseError.connectionFailed }

        try db.transaction {
            for message in messageList {
                let insert = messages.insert(
                    messageContactId <- message.contactId,
                    messageSender <- message.sender.rawValue,
                    messageContent <- message.content,
                    messageTimestamp <- message.timestamp
                )
                _ = try db.run(insert)
            }
        }
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
```

**Step 4: Create test file**

Create `Tests/WhatsAppAutoReplyTests/DatabaseManagerTests.swift`:

```swift
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
```

**Step 5: Build and run tests**

```bash
swift build
swift test
```

Expected: All tests pass

**Step 6: Commit**

```bash
git add Sources/ Tests/
git commit -m "feat: add database models and manager with SQLite"
```

---

## Task 3: Create WhatsApp Chat Parser

**Files:**
- Create: `Sources/WhatsAppAutoReply/Parser/ChatParser.swift`
- Create: `Tests/WhatsAppAutoReplyTests/ChatParserTests.swift`

**Step 1: Create ChatParser**

Create `Sources/WhatsAppAutoReply/Parser/ChatParser.swift`:

```swift
import Foundation

struct ParsedMessage {
    let timestamp: Date
    let sender: String
    let content: String
}

class ChatParser {
    private let userName: String
    private let dateFormatter: DateFormatter

    init(userName: String = "Iago Cavalcante") {
        self.userName = userName
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "dd/MM/yyyy, HH:mm:ss"
        self.dateFormatter.locale = Locale(identifier: "pt_BR")
    }

    func parseZipFile(at url: URL) throws -> (contactName: String, messages: [ParsedMessage]) {
        // Extract contact name from zip filename
        let filename = url.deletingPathExtension().lastPathComponent
        let contactName = filename.replacingOccurrences(of: "WhatsApp Chat - ", with: "")

        // Unzip and read _chat.txt
        let chatContent = try extractChatFromZip(url)
        let messages = parseChat(chatContent)

        return (contactName, messages)
    }

    private func extractChatFromZip(_ zipUrl: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", zipUrl.path, "_chat.txt"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let content = String(data: data, encoding: .utf8) else {
            throw ParserError.invalidEncoding
        }
        return content
    }

    func parseChat(_ content: String) -> [ParsedMessage] {
        var messages: [ParsedMessage] = []
        let lines = content.components(separatedBy: .newlines)

        // Pattern: [DD/MM/YYYY, HH:MM:SS] Sender: Message
        let pattern = #"^\[(\d{2}/\d{2}/\d{4}, \d{2}:\d{2}:\d{2})\] ([^:]+): (.+)$"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])

        var currentMessage: (date: String, sender: String, content: String)?

        for line in lines {
            let range = NSRange(line.startIndex..., in: line)

            if let match = regex?.firstMatch(in: line, options: [], range: range) {
                // Save previous message if exists
                if let current = currentMessage {
                    if let date = dateFormatter.date(from: current.date) {
                        messages.append(ParsedMessage(
                            timestamp: date,
                            sender: current.sender,
                            content: current.content
                        ))
                    }
                }

                // Parse new message
                let dateRange = Range(match.range(at: 1), in: line)!
                let senderRange = Range(match.range(at: 2), in: line)!
                let contentRange = Range(match.range(at: 3), in: line)!

                let dateStr = String(line[dateRange])
                let sender = String(line[senderRange])
                let content = String(line[contentRange])

                // Skip system messages and media
                if sender.contains("Messages and calls are end-to-end encrypted") ||
                   sender.contains("As mensagens e ligações são protegidas") ||
                   content.contains("<anexado:") ||
                   content.contains("<attached:") ||
                   content.contains("imagem ocultada") ||
                   content.contains("image omitted") {
                    currentMessage = nil
                    continue
                }

                currentMessage = (dateStr, sender, content)
            } else if currentMessage != nil {
                // Continuation of previous message (multiline)
                currentMessage?.content += "\n" + line
            }
        }

        // Don't forget last message
        if let current = currentMessage, let date = dateFormatter.date(from: current.date) {
            messages.append(ParsedMessage(
                timestamp: date,
                sender: current.sender,
                content: current.content
            ))
        }

        return messages
    }

    func convertToMessages(parsed: [ParsedMessage], contactId: Int64, contactName: String) -> [Message] {
        return parsed.map { pm in
            let sender: Message.Sender = pm.sender == userName ? .user : .contact
            return Message(
                contactId: contactId,
                sender: sender,
                content: pm.content,
                timestamp: pm.timestamp
            )
        }
    }

    enum ParserError: Error {
        case invalidEncoding
        case fileNotFound
    }
}
```

**Step 2: Create test file**

Create `Tests/WhatsAppAutoReplyTests/ChatParserTests.swift`:

```swift
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
```

**Step 3: Build and run tests**

```bash
swift build
swift test
```

Expected: All tests pass

**Step 4: Commit**

```bash
git add Sources/ Tests/
git commit -m "feat: add WhatsApp chat export parser"
```

---

## Task 4: Create Ollama Client

**Files:**
- Create: `Sources/WhatsAppAutoReply/Ollama/OllamaClient.swift`
- Create: `Tests/WhatsAppAutoReplyTests/OllamaClientTests.swift`

**Step 1: Create OllamaClient**

Create `Sources/WhatsAppAutoReply/Ollama/OllamaClient.swift`:

```swift
import Foundation

class OllamaClient {
    private let baseURL: URL
    private let model: String
    private let session: URLSession

    init(baseURL: URL = URL(string: "http://localhost:11434")!, model: String = "llama3.2:3b") {
        self.baseURL = baseURL
        self.model = model
        self.session = URLSession.shared
    }

    func generateResponse(prompt: String) async throws -> String {
        let url = baseURL.appendingPathComponent("api/generate")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.7,
                "num_predict": 100
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw OllamaError.httpError(httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = json["response"] as? String else {
            throw OllamaError.parseError
        }

        return responseText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func buildPrompt(contactName: String, examples: [Message], newMessage: String, userName: String = "Iago Cavalcante") -> String {
        var prompt = """
        You are \(userName). Respond exactly as he would based on these example conversations.
        Your responses should be in Portuguese (Brazilian), casual, short (1-2 sentences max).
        Use informal spelling, "kkkk" for laughing, and emojis when appropriate.
        Never explain yourself - just respond naturally.

        Example conversations with \(contactName):

        """

        // Group messages into conversation pairs
        var i = 0
        while i < examples.count - 1 {
            if examples[i].sender == .contact && examples[i + 1].sender == .user {
                prompt += "\(contactName): \(examples[i].content)\n"
                prompt += "\(userName): \(examples[i + 1].content)\n\n"
            }
            i += 1
        }

        prompt += """

        Now respond to this new message in the same style:
        \(contactName): \(newMessage)
        \(userName):
        """

        return prompt
    }

    func isAvailable() async -> Bool {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    enum OllamaError: Error {
        case invalidResponse
        case httpError(Int)
        case parseError
        case notRunning
    }
}
```

**Step 2: Create test file**

Create `Tests/WhatsAppAutoReplyTests/OllamaClientTests.swift`:

```swift
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
            contactName: "Amor",
            examples: examples,
            newMessage: "Tudo bem?"
        )

        XCTAssertTrue(prompt.contains("Amor: Quer pizza?"))
        XCTAssertTrue(prompt.contains("Iago Cavalcante: bora"))
        XCTAssertTrue(prompt.contains("Amor: Tudo bem?"))
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
```

**Step 3: Build and run tests**

```bash
swift build
swift test
```

Expected: Tests pass (integration test skipped if Ollama not running)

**Step 4: Commit**

```bash
git add Sources/ Tests/
git commit -m "feat: add Ollama client for response generation"
```

---

## Task 5: Create WhatsApp Monitor with Accessibility API

**Files:**
- Create: `Sources/WhatsAppAutoReply/Monitor/WhatsAppMonitor.swift`
- Create: `Sources/WhatsAppAutoReply/Monitor/AccessibilityHelper.swift`

**Step 1: Create AccessibilityHelper**

Create `Sources/WhatsAppAutoReply/Monitor/AccessibilityHelper.swift`:

```swift
import ApplicationServices
import AppKit

class AccessibilityHelper {

    static func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func findWhatsAppWindow() -> AXUIElement? {
        let apps = NSWorkspace.shared.runningApplications
        guard let whatsApp = apps.first(where: { $0.bundleIdentifier == "net.whatsapp.WhatsApp" }) else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(whatsApp.processIdentifier)

        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)

        guard result == .success,
              let windows = windowsValue as? [AXUIElement],
              let mainWindow = windows.first else {
            return nil
        }

        return mainWindow
    }

    static func getElementValue(_ element: AXUIElement, attribute: String) -> Any? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return result == .success ? value : nil
    }

    static func getChildren(_ element: AXUIElement) -> [AXUIElement] {
        var childrenValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)

        guard result == .success, let children = childrenValue as? [AXUIElement] else {
            return []
        }
        return children
    }

    static func getRole(_ element: AXUIElement) -> String? {
        getElementValue(element, attribute: kAXRoleAttribute as String) as? String
    }

    static func getValue(_ element: AXUIElement) -> String? {
        getElementValue(element, attribute: kAXValueAttribute as String) as? String
    }

    static func getTitle(_ element: AXUIElement) -> String? {
        getElementValue(element, attribute: kAXTitleAttribute as String) as? String
    }

    static func getDescription(_ element: AXUIElement) -> String? {
        getElementValue(element, attribute: kAXDescriptionAttribute as String) as? String
    }

    static func setFocus(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)
    }

    static func typeText(_ text: String) {
        for char in text {
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)

            var unicodeChar = Array(String(char).utf16)
            keyDown?.keyboardSetUnicodeString(stringLength: unicodeChar.count, unicodeString: &unicodeChar)
            keyUp?.keyboardSetUnicodeString(stringLength: unicodeChar.count, unicodeString: &unicodeChar)

            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)

            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    static func pressEnter() {
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
```

**Step 2: Create WhatsAppMonitor**

Create `Sources/WhatsAppAutoReply/Monitor/WhatsAppMonitor.swift`:

```swift
import Foundation
import ApplicationServices
import Combine

struct DetectedMessage {
    let contactName: String
    let content: String
    let timestamp: Date
}

class WhatsAppMonitor: ObservableObject {
    @Published var isMonitoring = false
    @Published var lastDetectedMessage: DetectedMessage?
    @Published var whatsAppRunning = false
    @Published var hasAccessibilityPermission = false

    private var timer: Timer?
    private var lastMessageHash: Int = 0

    var onNewMessage: ((DetectedMessage) -> Void)?

    init() {
        checkPermissions()
    }

    func checkPermissions() {
        hasAccessibilityPermission = AccessibilityHelper.checkAccessibilityPermission()
        whatsAppRunning = AccessibilityHelper.findWhatsAppWindow() != nil
    }

    func startMonitoring() {
        guard hasAccessibilityPermission else {
            print("No accessibility permission")
            return
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
    }

    private func checkForNewMessages() {
        guard let window = AccessibilityHelper.findWhatsAppWindow() else {
            whatsAppRunning = false
            return
        }
        whatsAppRunning = true

        // Find the active chat name and last message
        if let (contactName, lastMessage) = findLastMessage(in: window) {
            let messageHash = "\(contactName):\(lastMessage)".hashValue

            if messageHash != lastMessageHash {
                lastMessageHash = messageHash

                let detected = DetectedMessage(
                    contactName: contactName,
                    content: lastMessage,
                    timestamp: Date()
                )

                lastDetectedMessage = detected
                onNewMessage?(detected)
            }
        }
    }

    private func findLastMessage(in window: AXUIElement) -> (contactName: String, message: String)? {
        // This navigates the WhatsApp accessibility tree
        // The structure may vary with WhatsApp versions

        // Try to find the chat header (contact name) and message list
        var contactName: String?
        var lastMessage: String?

        func searchElement(_ element: AXUIElement, depth: Int = 0) {
            guard depth < 15 else { return }

            let role = AccessibilityHelper.getRole(element)
            let value = AccessibilityHelper.getValue(element)
            let title = AccessibilityHelper.getTitle(element)

            // Look for static text elements that contain messages
            if role == "AXStaticText", let text = value ?? title {
                // Skip system messages and timestamps
                if !text.isEmpty &&
                   !text.contains(":") && // timestamps
                   text.count > 2 &&
                   text.count < 500 {
                    lastMessage = text
                }
            }

            // Look for the contact/chat name in header area
            if role == "AXStaticText" || role == "AXButton",
               let text = value ?? title,
               text.count > 1 && text.count < 50 && contactName == nil {
                // Heuristic: contact name is usually in the header
                if !text.contains("WhatsApp") && !text.hasPrefix("[") {
                    contactName = text
                }
            }

            for child in AccessibilityHelper.getChildren(element) {
                searchElement(child, depth: depth + 1)
            }
        }

        searchElement(window)

        if let name = contactName, let message = lastMessage {
            return (name, message)
        }
        return nil
    }

    func sendMessage(_ text: String) {
        guard let window = AccessibilityHelper.findWhatsAppWindow() else { return }

        // Find the text input field
        func findInputField(_ element: AXUIElement) -> AXUIElement? {
            let role = AccessibilityHelper.getRole(element)

            if role == "AXTextArea" || role == "AXTextField" {
                return element
            }

            for child in AccessibilityHelper.getChildren(element) {
                if let found = findInputField(child) {
                    return found
                }
            }
            return nil
        }

        guard let inputField = findInputField(window) else {
            print("Could not find input field")
            return
        }

        // Focus and type
        AccessibilityHelper.setFocus(inputField)
        Thread.sleep(forTimeInterval: 0.1)

        AccessibilityHelper.typeText(text)
        Thread.sleep(forTimeInterval: 0.1)

        AccessibilityHelper.pressEnter()
    }
}
```

**Step 3: Build**

```bash
swift build
```

Expected: Build succeeds

**Step 4: Commit**

```bash
git add Sources/
git commit -m "feat: add WhatsApp monitor with Accessibility API"
```

---

## Task 6: Create Response Generator Service

**Files:**
- Create: `Sources/WhatsAppAutoReply/Services/ResponseGenerator.swift`

**Step 1: Create ResponseGenerator**

Create `Sources/WhatsAppAutoReply/Services/ResponseGenerator.swift`:

```swift
import Foundation

class ResponseGenerator {
    private let ollamaClient: OllamaClient
    private let dbManager: DatabaseManager
    private let userName: String

    init(
        ollamaClient: OllamaClient = OllamaClient(),
        dbManager: DatabaseManager = .shared,
        userName: String = "Iago Cavalcante"
    ) {
        self.ollamaClient = ollamaClient
        self.dbManager = dbManager
        self.userName = userName
    }

    func generateResponse(for contactName: String, message: String) async throws -> String? {
        // Find contact
        guard let contact = try dbManager.getContactByName(contactName) else {
            print("Contact not found: \(contactName)")
            return nil
        }

        // Check if auto-reply is enabled
        guard contact.autoReplyEnabled else {
            print("Auto-reply disabled for: \(contactName)")
            return nil
        }

        // Get example messages for this contact
        let examples = try dbManager.getMessagesForContact(contactId: contact.id, limit: 50)

        guard examples.count >= 10 else {
            print("Not enough message history for: \(contactName)")
            return nil
        }

        // Find conversation pairs (contact message followed by user response)
        let pairs = findConversationPairs(messages: examples)

        guard pairs.count >= 5 else {
            print("Not enough conversation pairs for: \(contactName)")
            return nil
        }

        // Take most recent relevant pairs
        let recentPairs = Array(pairs.suffix(15))

        // Build prompt
        let prompt = ollamaClient.buildPrompt(
            contactName: contactName,
            examples: recentPairs.flatMap { [$0.0, $0.1] },
            newMessage: message,
            userName: userName
        )

        // Generate response
        let response = try await ollamaClient.generateResponse(prompt: prompt)

        // Clean up response
        return cleanResponse(response)
    }

    private func findConversationPairs(messages: [Message]) -> [(Message, Message)] {
        var pairs: [(Message, Message)] = []

        for i in 0..<(messages.count - 1) {
            if messages[i].sender == .contact && messages[i + 1].sender == .user {
                pairs.append((messages[i], messages[i + 1]))
            }
        }

        return pairs
    }

    private func cleanResponse(_ response: String) -> String {
        var cleaned = response

        // Remove any accidental self-references
        let prefixes = ["Iago Cavalcante:", "Iago:", "Me:"]
        for prefix in prefixes {
            if cleaned.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
            }
        }

        // Trim and limit length
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Limit to reasonable length
        if cleaned.count > 200 {
            // Find a natural break point
            if let range = cleaned.range(of: ".", options: .backwards, range: cleaned.startIndex..<cleaned.index(cleaned.startIndex, offsetBy: 200)) {
                cleaned = String(cleaned[..<range.upperBound])
            } else {
                cleaned = String(cleaned.prefix(200))
            }
        }

        return cleaned
    }
}
```

**Step 2: Build**

```bash
swift build
```

Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/
git commit -m "feat: add response generator service"
```

---

## Task 7: Update Menu Bar UI with Full Functionality

**Files:**
- Modify: `Sources/WhatsAppAutoReply/Views/MenuBarView.swift`
- Create: `Sources/WhatsAppAutoReply/ViewModels/AppViewModel.swift`

**Step 1: Create AppViewModel**

Create `Sources/WhatsAppAutoReply/ViewModels/AppViewModel.swift`:

```swift
import Foundation
import SwiftUI
import Combine

@MainActor
class AppViewModel: ObservableObject {
    @Published var contacts: [Contact] = []
    @Published var isOllamaRunning = false
    @Published var pendingResponse: PendingResponse?
    @Published var responseLog: [ResponseLogEntry] = []

    private let dbManager = DatabaseManager.shared
    private let monitor = WhatsAppMonitor()
    private let responseGenerator = ResponseGenerator()
    private let ollamaClient = OllamaClient()

    private var cancellables = Set<AnyCancellable>()

    struct PendingResponse {
        let contactName: String
        let incomingMessage: String
        let response: String
        let timestamp: Date
    }

    struct ResponseLogEntry: Identifiable {
        let id = UUID()
        let contactName: String
        let incomingMessage: String
        let response: String
        let timestamp: Date
    }

    var hasAccessibilityPermission: Bool {
        monitor.hasAccessibilityPermission
    }

    var isWhatsAppRunning: Bool {
        monitor.whatsAppRunning
    }

    init() {
        loadContacts()
        setupMonitor()
        checkOllama()
    }

    func loadContacts() {
        do {
            contacts = try dbManager.getAllContacts()
        } catch {
            print("Failed to load contacts: \(error)")
        }
    }

    func checkOllama() {
        Task {
            isOllamaRunning = await ollamaClient.isAvailable()
        }
    }

    func setupMonitor() {
        monitor.onNewMessage = { [weak self] detected in
            Task { @MainActor in
                await self?.handleNewMessage(detected)
            }
        }

        // Check permissions periodically
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.monitor.checkPermissions()
            self?.checkOllama()
        }
    }

    func toggleAutoReply(for contact: Contact) {
        do {
            let newState = !contact.autoReplyEnabled
            try dbManager.updateContactAutoReply(id: contact.id, enabled: newState)

            // Update local state
            if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
                contacts[index].autoReplyEnabled = newState
            }

            // Start/stop monitoring based on any active contacts
            updateMonitoringState()
        } catch {
            print("Failed to toggle auto-reply: \(error)")
        }
    }

    private func updateMonitoringState() {
        let hasActiveContacts = contacts.contains { $0.autoReplyEnabled }

        if hasActiveContacts && !monitor.isMonitoring {
            monitor.startMonitoring()
        } else if !hasActiveContacts && monitor.isMonitoring {
            monitor.stopMonitoring()
        }
    }

    private func handleNewMessage(_ detected: DetectedMessage) async {
        // Check if this contact has auto-reply enabled
        guard contacts.first(where: { $0.name == detected.contactName && $0.autoReplyEnabled }) != nil else {
            return
        }

        do {
            if let response = try await responseGenerator.generateResponse(
                for: detected.contactName,
                message: detected.content
            ) {
                // Set pending response (user has 5 seconds to cancel)
                pendingResponse = PendingResponse(
                    contactName: detected.contactName,
                    incomingMessage: detected.content,
                    response: response,
                    timestamp: Date()
                )

                // Wait 5 seconds then send if not cancelled
                try await Task.sleep(nanoseconds: 5_000_000_000)

                if pendingResponse != nil {
                    sendPendingResponse()
                }
            }
        } catch {
            print("Failed to generate response: \(error)")
        }
    }

    func sendPendingResponse() {
        guard let pending = pendingResponse else { return }

        monitor.sendMessage(pending.response)

        responseLog.insert(ResponseLogEntry(
            contactName: pending.contactName,
            incomingMessage: pending.incomingMessage,
            response: pending.response,
            timestamp: pending.timestamp
        ), at: 0)

        pendingResponse = nil
    }

    func cancelPendingResponse() {
        pendingResponse = nil
    }

    func importChatExport(url: URL) {
        let parser = ChatParser()

        do {
            let (contactName, parsed) = try parser.parseZipFile(at: url)

            // Create or get contact
            var contact: Contact
            if let existing = try dbManager.getContactByName(contactName) {
                contact = existing
            } else {
                let id = try dbManager.insertContact(Contact(name: contactName))
                contact = Contact(id: id, name: contactName)
            }

            // Convert and insert messages
            let messages = parser.convertToMessages(
                parsed: parsed,
                contactId: contact.id,
                contactName: contactName
            )
            try dbManager.insertMessages(messages)

            // Refresh contacts list
            loadContacts()

            print("Imported \(messages.count) messages for \(contactName)")
        } catch {
            print("Import failed: \(error)")
        }
    }

    func requestAccessibilityPermission() {
        _ = AccessibilityHelper.checkAccessibilityPermission()
    }
}
```

**Step 2: Update MenuBarView**

Replace `Sources/WhatsAppAutoReply/Views/MenuBarView.swift`:

```swift
import SwiftUI

struct MenuBarView: View {
    @StateObject private var viewModel = AppViewModel()
    @State private var showingImporter = false
    @State private var showingLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "message.fill")
                    .foregroundColor(.green)
                Text("WhatsApp Auto-Reply")
                    .font(.headline)
            }
            .padding(.bottom, 4)

            // Status indicators
            StatusRow(
                label: "Accessibility",
                isOK: viewModel.hasAccessibilityPermission,
                action: viewModel.hasAccessibilityPermission ? nil : viewModel.requestAccessibilityPermission
            )

            StatusRow(
                label: "WhatsApp",
                isOK: viewModel.isWhatsAppRunning
            )

            StatusRow(
                label: "Ollama",
                isOK: viewModel.isOllamaRunning
            )

            Divider()

            // Pending response notification
            if let pending = viewModel.pendingResponse {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sending in 5s...")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text(pending.response)
                        .font(.caption)
                        .lineLimit(2)

                    Button("Cancel") {
                        viewModel.cancelPendingResponse()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)

                Divider()
            }

            // Contacts list
            if viewModel.contacts.isEmpty {
                Text("No contacts imported")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                Text("Contacts")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(viewModel.contacts) { contact in
                    ContactRow(contact: contact) {
                        viewModel.toggleAutoReply(for: contact)
                    }
                }
            }

            Divider()

            // Actions
            Button("Import Chat Export...") {
                showingImporter = true
            }

            Button("View Response Log (\(viewModel.responseLog.count))") {
                showingLog = true
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 280)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                viewModel.importChatExport(url: url)
            }
        }
        .sheet(isPresented: $showingLog) {
            ResponseLogView(entries: viewModel.responseLog)
        }
    }
}

struct StatusRow: View {
    let label: String
    let isOK: Bool
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Circle()
                .fill(isOK ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
            Spacer()

            if !isOK, let action = action {
                Button("Enable") {
                    action()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }
}

struct ContactRow: View {
    let contact: Contact
    let onToggle: () -> Void

    var body: some View {
        HStack {
            Circle()
                .fill(contact.autoReplyEnabled ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(contact.name)
                .font(.system(size: 13))
            Spacer()

            Toggle("", isOn: Binding(
                get: { contact.autoReplyEnabled },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }
}

struct ResponseLogView: View {
    let entries: [AppViewModel.ResponseLogEntry]
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack {
            HStack {
                Text("Response Log")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()

            if entries.isEmpty {
                Text("No responses sent yet")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.contactName)
                                .font(.caption)
                                .bold()
                            Spacer()
                            Text(entry.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Text("← \(entry.incomingMessage)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("→ \(entry.response)")
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 400, height: 300)
    }
}
```

**Step 3: Build**

```bash
swift build
```

Expected: Build succeeds

**Step 4: Commit**

```bash
git add Sources/
git commit -m "feat: implement full menu bar UI with contact management"
```

---

## Task 8: Add Info.plist and Build Configuration

**Files:**
- Create: `Sources/WhatsAppAutoReply/Info.plist`
- Modify: `Package.swift`

**Step 1: Create Info.plist**

Create `Sources/WhatsAppAutoReply/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>WhatsApp Auto-Reply</string>
    <key>CFBundleIdentifier</key>
    <string>com.iagocavalcante.whatsapp-auto-reply</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>WhatsApp Auto-Reply needs accessibility access to monitor and respond to WhatsApp messages.</string>
</dict>
</plist>
```

**Step 2: Build release**

```bash
swift build -c release
```

Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/ Package.swift
git commit -m "feat: add Info.plist for accessibility permission prompt"
```

---

## Task 9: Integration Test and Final Polish

**Step 1: Verify Ollama is ready**

```bash
ollama list | grep llama3.2
```

If not present, pull it:
```bash
ollama pull llama3.2:3b
```

**Step 2: Run the app**

```bash
swift run
```

**Step 3: Test import**

1. Click menu bar icon
2. Click "Import Chat Export..."
3. Select one of the WhatsApp zip files
4. Verify contact appears in list

**Step 4: Test auto-reply toggle**

1. Toggle a contact's auto-reply switch
2. Verify status changes

**Step 5: Final commit**

```bash
git add -A
git commit -m "chore: integration testing complete"
```

---

## Summary

**Total Tasks:** 9

**Key files created:**
- `Package.swift` - Swift package definition
- `Sources/WhatsAppAutoReply/App.swift` - Main app entry
- `Sources/WhatsAppAutoReply/Models/` - Contact, Message models
- `Sources/WhatsAppAutoReply/Database/DatabaseManager.swift` - SQLite operations
- `Sources/WhatsAppAutoReply/Parser/ChatParser.swift` - WhatsApp export parser
- `Sources/WhatsAppAutoReply/Ollama/OllamaClient.swift` - Ollama API client
- `Sources/WhatsAppAutoReply/Monitor/` - WhatsApp accessibility monitoring
- `Sources/WhatsAppAutoReply/Services/ResponseGenerator.swift` - Response logic
- `Sources/WhatsAppAutoReply/Views/MenuBarView.swift` - UI
- `Sources/WhatsAppAutoReply/ViewModels/AppViewModel.swift` - State management

**To run after implementation:**
```bash
swift build -c release
.build/release/WhatsAppAutoReply
```
