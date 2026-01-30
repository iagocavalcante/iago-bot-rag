import Foundation
import ApplicationServices
import AppKit
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
    @Published var debugInfo: String = ""

    private var timer: Timer?
    private var lastMessageHashes: [String: Int] = [:] // Track per contact

    var onNewMessage: ((DetectedMessage) -> Void)?
    var onDebugLog: ((String) -> Void)?

    private func debugLog(_ msg: String) {
        debugInfo = msg
        onDebugLog?(msg)
        print("[Monitor] \(msg)")
    }

    init() {
        checkPermissions()
    }

    func checkPermissions() {
        hasAccessibilityPermission = AccessibilityHelper.checkAccessibilityPermission()
        whatsAppRunning = AccessibilityHelper.findWhatsAppWindow() != nil
    }

    func startMonitoring() {
        guard hasAccessibilityPermission else {
            debugLog("Cannot start - no accessibility permission")
            return
        }

        debugLog("Starting monitoring...")
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

    private var lastParseFailureLog: Date = .distantPast

    private func checkForNewMessages() {
        guard let window = AccessibilityHelper.findWhatsAppWindow() else {
            if whatsAppRunning {
                debugLog("WhatsApp window not found")
            }
            whatsAppRunning = false
            return
        }
        whatsAppRunning = true

        // Find ALL visible messages (not just one)
        let messages = findAllMessages(in: window)

        if messages.isEmpty {
            // Log parse failures at most once per minute
            if Date().timeIntervalSince(lastParseFailureLog) > 60 {
                lastParseFailureLog = Date()
                debugLog("No messages found in WhatsApp")
            }
            return
        }

        // Check each message for new content
        for (contactName, messageContent) in messages {
            let messageHash = messageContent.hashValue
            let previousHash = lastMessageHashes[contactName] ?? 0

            if messageHash != previousHash {
                lastMessageHashes[contactName] = messageHash
                debugLog("NEW MESSAGE from '\(contactName)': '\(messageContent.prefix(40))...'")

                let detected = DetectedMessage(
                    contactName: contactName,
                    content: messageContent,
                    timestamp: Date()
                )

                lastDetectedMessage = detected
                onNewMessage?(detected)
            }
        }
    }

    /// Dump accessibility tree for debugging - shows more elements
    func dumpAccessibilityTree() -> String {
        guard let window = AccessibilityHelper.findWhatsAppWindow() else {
            return "WhatsApp window not found"
        }

        var output = "WhatsApp Accessibility Tree:\n"
        var allElements: [(role: String, text: String, depth: Int, selected: Bool, focused: Bool)] = []

        func dumpElement(_ element: AXUIElement, depth: Int = 0) {
            guard depth < 12 else { return }

            let role = AccessibilityHelper.getRole(element) ?? "?"
            let value = AccessibilityHelper.getValue(element)
            let title = AccessibilityHelper.getTitle(element)
            let desc = AccessibilityHelper.getDescription(element)
            let selected = AccessibilityHelper.isSelected(element)
            let focused = AccessibilityHelper.isFocused(element)

            let text = cleanText(value ?? title ?? desc ?? "")
            if !text.isEmpty || selected || focused {
                allElements.append((role, text, depth, selected, focused))
            }

            for child in AccessibilityHelper.getChildren(element) {
                dumpElement(child, depth: depth + 1)
            }
        }

        dumpElement(window)

        // Show all elements found
        for (role, text, depth, selected, focused) in allElements.prefix(100) {
            let indent = String(repeating: "  ", count: depth)
            let preview = String(text.prefix(60)).replacingOccurrences(of: "\n", with: "\\n")
            var flags = ""
            if selected { flags += " [SEL]" }
            if focused { flags += " [FOC]" }
            output += "\(indent)[\(role)]\(flags) \(preview)\n"
        }

        return output
    }

    /// Strip invisible Unicode characters (LTR/RTL marks, etc.)
    private func cleanText(_ text: String) -> String {
        // Remove common invisible Unicode characters used by WhatsApp
        var cleaned = text
        let invisibleChars: [Character] = [
            "\u{200E}", // Left-to-Right Mark
            "\u{200F}", // Right-to-Left Mark
            "\u{200B}", // Zero Width Space
            "\u{FEFF}", // BOM
        ]
        for char in invisibleChars {
            cleaned = cleaned.replacingOccurrences(of: String(char), with: "")
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Message Detection

    /// Find ALL visible messages from WhatsApp (sidebar + active chat)
    private func findAllMessages(in window: AXUIElement) -> [(contactName: String, message: String)] {
        // Collect all text elements from the WhatsApp window
        var allTexts: [String] = []

        func collectTexts(_ element: AXUIElement, depth: Int = 0) {
            guard depth < 20 else { return }

            let value = AccessibilityHelper.getValue(element)
            let title = AccessibilityHelper.getTitle(element)

            if let text = value ?? title, !text.isEmpty {
                let cleaned = cleanText(text)
                if !cleaned.isEmpty {
                    allTexts.append(cleaned)
                }
            }

            for child in AccessibilityHelper.getChildren(element) {
                collectTexts(child, depth: depth + 1)
            }
        }

        collectTexts(window)

        var results: [(String, String)] = []
        var seenContacts: Set<String> = [] // Avoid duplicates per contact

        // Parse all texts for messages
        for text in allTexts {
            // Skip media messages
            if isMediaMessage(text) {
                continue
            }

            // Skip sent messages
            if text.hasPrefix("Your message") || text.hasPrefix("Your photo") ||
               text.hasPrefix("Your sticker") || text.contains("Sent to") {
                continue
            }

            // Try all patterns
            var parsed: (String, String)?

            // Pattern 1: DM - "message, <content>, <time>, Received from <Name>"
            if parsed == nil {
                parsed = parseDMMessage(text)
            }

            // Pattern 2: Group - "message, <content> from <Sender>, <time>, Received in <Group>"
            if parsed == nil {
                parsed = parseGroupMessage(text)
            }

            // Pattern 3: Sidebar - "Message from <Name>, <content>"
            if parsed == nil {
                parsed = parseSidebarMessage(text)
            }

            // Add to results if parsed and not already seen
            if let (contact, message) = parsed {
                if !seenContacts.contains(contact) {
                    seenContacts.insert(contact)
                    results.append((contact, message))
                }
            }
        }

        return results
    }

    /// Legacy single-message function (for compatibility)
    private func findLastMessage(in window: AXUIElement) -> (contactName: String, message: String)? {
        return findAllMessages(in: window).first
    }

    private func isMediaMessage(_ text: String) -> Bool {
        let mediaPatterns = ["sticker", "Sticker", "image,", "video,", "Video from",
                            "Image from", "GIF,", "Audio,", "Link,", "Duration:",
                            "Photo,", "Document,", "Contact card"]
        return mediaPatterns.contains { text.contains($0) }
    }

    /// Check if message contains reply/quote indicators
    private func isReplyToUser(_ text: String) -> Bool {
        let lowerText = text.lowercased()
        let replyIndicators = [
            // English
            "replied to your message",
            "replying to your message",
            "reply to you",
            "quoted your message",
            // Portuguese
            "respondeu à sua mensagem",
            "respondeu a sua mensagem",
            "respondendo à sua mensagem",
            "citou sua mensagem",
            "em resposta à sua",
            // WhatsApp accessibility patterns
            "reply,",
            "quoted,",
        ]

        return replyIndicators.contains { lowerText.contains($0) }
    }

    /// Parse DM format: "message, <content>, <time>, Received from <Name>"
    private func parseDMMessage(_ text: String) -> (String, String)? {
        guard text.hasPrefix("message, ") && text.contains("Received from ") else {
            return nil
        }

        // Extract contact name after "Received from "
        guard let receivedRange = text.range(of: "Received from ") else { return nil }
        var contactName = String(text[receivedRange.upperBound...])
        contactName = cleanStatusSuffix(contactName)

        guard !contactName.isEmpty else { return nil }

        // Extract content between "message, " and timestamp
        let afterPrefix = String(text.dropFirst(9)) // Remove "message, "
        guard let content = extractContentBeforeTimestamp(afterPrefix) else { return nil }

        // Don't log here - log only when it's actually a new message in checkForNewMessages
        return (contactName, content)
    }

    /// Parse Group format: "message, <content> from <Sender>, <time>, Received in <Group>"
    private func parseGroupMessage(_ text: String) -> (String, String)? {
        guard text.hasPrefix("message, ") && text.contains("Received in ") else {
            return nil
        }

        // Extract group name after "Received in "
        guard let receivedRange = text.range(of: "Received in ") else { return nil }
        var groupName = String(text[receivedRange.upperBound...])
        groupName = cleanStatusSuffix(groupName)

        guard !groupName.isEmpty else { return nil }

        // Extract content between "message, " and timestamp
        let afterPrefix = String(text.dropFirst(9)) // Remove "message, "
        guard var content = extractContentBeforeTimestamp(afterPrefix) else { return nil }

        // Remove " from <Sender>" suffix from content
        if let fromRange = content.range(of: #" from [^,]+$"#, options: .regularExpression) {
            content = String(content[..<fromRange.lowerBound])
        }

        // Don't log here - log only when it's actually a new message
        return (groupName, content)
    }

    /// Parse Sidebar format: "Message from <Name>, <content>"
    /// For groups: "Message from <Sender>, <content>, Received in <Group>"
    private func parseSidebarMessage(_ text: String) -> (String, String)? {
        guard text.hasPrefix("Message from ") else {
            return nil
        }

        let afterPrefix = String(text.dropFirst(13)) // Remove "Message from "

        // Check if this is a group message (contains "Received in ")
        if afterPrefix.contains("Received in ") {
            // Extract group name from "Received in <Group>"
            guard let receivedRange = afterPrefix.range(of: "Received in ") else { return nil }
            var groupName = String(afterPrefix[receivedRange.upperBound...])
            groupName = cleanStatusSuffix(groupName)

            guard !groupName.isEmpty else { return nil }

            // Extract content between sender and timestamp
            guard let commaIndex = afterPrefix.firstIndex(of: ",") else { return nil }
            var content = String(afterPrefix[afterPrefix.index(after: commaIndex)...])
                .trimmingCharacters(in: .whitespaces)

            // Remove the "Received in <Group>" suffix from content
            if let receivedInContent = content.range(of: ", Received in ") {
                content = String(content[..<receivedInContent.lowerBound])
            }

            // Also try to clean timestamp from content
            if let timestampRange = content.range(of: #", \d{1,2}:\d{2},"#, options: .regularExpression) {
                content = String(content[..<timestampRange.lowerBound])
            }

            return (groupName, content)
        }

        // Regular DM sidebar message
        // Find first comma to split name and content
        guard let commaIndex = afterPrefix.firstIndex(of: ",") else { return nil }

        var contactName = String(afterPrefix[..<commaIndex])
        // Remove "Maybe " prefix for unsaved contacts
        if contactName.hasPrefix("Maybe ") {
            contactName = String(contactName.dropFirst(6))
        }

        let content = String(afterPrefix[afterPrefix.index(after: commaIndex)...])
            .trimmingCharacters(in: .whitespaces)

        guard !contactName.isEmpty && !content.isEmpty else { return nil }

        // Don't log here - log only when it's actually a new message
        return (contactName, content)
    }

    /// Remove WhatsApp status suffixes (Pinned, Muted, etc.)
    private func cleanStatusSuffix(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = [", Pinned", ", Muted", ", Archived", ", Starred", ",Pinned", ",Muted"]
        for suffix in suffixes {
            if result.hasSuffix(suffix) {
                result = String(result.dropLast(suffix.count))
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Extract message content before timestamp pattern
    private func extractContentBeforeTimestamp(_ text: String) -> String? {
        // Pattern: ", HH:MM," (e.g., ", 22:30,")
        if let range = text.range(of: #", \d{1,2}:\d{2},"#, options: .regularExpression) {
            let content = String(text[..<range.lowerBound])
            return content.isEmpty ? nil : content
        }
        // Pattern: ", DDMonthatHH:MM" (e.g., ", 29Januaryat22:55")
        if let range = text.range(of: #", \d{1,2}[A-Za-z]+at\d{1,2}:\d{2}"#, options: .regularExpression) {
            let content = String(text[..<range.lowerBound])
            return content.isEmpty ? nil : content
        }
        // Pattern: ", DDMonthYYYY" (e.g., ", 13October2024")
        if let range = text.range(of: #", \d{1,2}\D+\d{4}"#, options: .regularExpression) {
            let content = String(text[..<range.lowerBound])
            return content.isEmpty ? nil : content
        }
        // Fallback: first part before ", "
        let parts = text.components(separatedBy: ", ")
        return parts.first
    }

    // MARK: - Send Message

    func sendMessage(_ text: String, to contactName: String? = nil) {
        debugLog("Attempting to send message (background): '\(text.prefix(30))...'")

        guard let window = AccessibilityHelper.findWhatsAppWindow() else {
            debugLog("ERROR: WhatsApp window not found for sending")
            return
        }

        // If contact name provided, select that chat first
        if let contact = contactName {
            if !selectChat(contact, in: window) {
                debugLog("WARNING: Could not select chat for '\(contact)', sending to current chat")
            }
        }

        // Find the text input field
        func findInputField(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
            guard depth < 15 else { return nil }

            let role = AccessibilityHelper.getRole(element)

            // WhatsApp input field might be AXTextArea, AXTextField
            if role == "AXTextArea" || role == "AXTextField" {
                return element
            }

            for child in AccessibilityHelper.getChildren(element) {
                if let found = findInputField(child, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }

        // Find send button by looking for button with "Send" description or similar
        func findSendButton(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
            guard depth < 15 else { return nil }

            let role = AccessibilityHelper.getRole(element)
            let desc = AccessibilityHelper.getDescription(element)?.lowercased() ?? ""
            let title = AccessibilityHelper.getTitle(element)?.lowercased() ?? ""

            // Look for send button
            if role == "AXButton" && (desc.contains("send") || title.contains("send") || desc.contains("enviar")) {
                return element
            }

            for child in AccessibilityHelper.getChildren(element) {
                if let found = findSendButton(child, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }

        guard let inputField = findInputField(window) else {
            debugLog("ERROR: Could not find input field in WhatsApp")
            return
        }

        // Try to set value directly via accessibility (no focus needed)
        debugLog("Setting text via accessibility...")
        if AccessibilityHelper.setValue(inputField, value: text) {
            debugLog("Text set successfully via accessibility")
            Thread.sleep(forTimeInterval: 0.3)

            // Try to find and click send button
            if let sendButton = findSendButton(window) {
                debugLog("Found send button, clicking...")
                if AccessibilityHelper.clickElement(sendButton) {
                    debugLog("Message sent via send button (no focus)")
                    return
                }
            }

            // Fallback: focus input and press Enter via CGEvent to PID
            debugLog("Send button not found, focusing input and pressing Enter...")
            AccessibilityHelper.setFocus(inputField)
            Thread.sleep(forTimeInterval: 0.1)
            AccessibilityHelper.pressEnter()
            Thread.sleep(forTimeInterval: 0.2)
            debugLog("Message sent via Enter key (no window activation)")
            return
        }

        // Fallback: use clipboard method (requires focus)
        debugLog("Direct value set failed, falling back to clipboard method...")
        fallbackSendWithFocus(text: text, inputField: inputField)
    }

    /// Select a chat by clicking on the contact in sidebar
    private func selectChat(_ contactName: String, in window: AXUIElement) -> Bool {
        debugLog("Selecting chat for '\(contactName)'...")

        // Find the chat cell in sidebar that matches the contact name
        func findChatCell(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
            guard depth < 20 else { return nil }

            let role = AccessibilityHelper.getRole(element)
            let value = AccessibilityHelper.getValue(element)
            let title = AccessibilityHelper.getTitle(element)
            let desc = AccessibilityHelper.getDescription(element)

            // Check if this element contains the contact name
            let text = value ?? title ?? desc ?? ""

            // Sidebar chat cells often have "Message from <Name>" pattern
            // Or just the contact name as title/description
            if text.contains(contactName) || text.contains("Message from \(contactName)") {
                // Found matching element - if it's clickable (button/cell), return it
                if role == "AXButton" || role == "AXCell" || role == "AXStaticText" {
                    debugLog("Found chat cell: [\(role ?? "?")] '\(text.prefix(40))'")
                    return element
                }
            }

            for child in AccessibilityHelper.getChildren(element) {
                if let found = findChatCell(child, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }

        if let chatCell = findChatCell(window) {
            debugLog("Clicking on chat cell...")
            if AccessibilityHelper.clickElement(chatCell) {
                Thread.sleep(forTimeInterval: 0.5) // Wait for chat to load
                debugLog("Chat selected successfully")
                return true
            }
        }

        debugLog("Could not find chat cell for '\(contactName)'")
        return false
    }

    private func fallbackSendWithFocus(text: String, inputField: AXUIElement) {
        // Bring WhatsApp to front (only as fallback)
        if let whatsApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "net.whatsapp.WhatsApp" }) {
            whatsApp.activate(options: .activateIgnoringOtherApps)
            Thread.sleep(forTimeInterval: 0.3)
        }

        debugLog("Focusing input field...")
        AccessibilityHelper.setFocus(inputField)
        Thread.sleep(forTimeInterval: 0.3)

        AXUIElementPerformAction(inputField, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.2)

        debugLog("Pasting message via clipboard...")
        AccessibilityHelper.pasteText(text)
        Thread.sleep(forTimeInterval: 0.8)

        debugLog("Pressing Enter to send...")
        AccessibilityHelper.pressEnter()
        Thread.sleep(forTimeInterval: 0.3)

        debugLog("Message send completed (with focus)")
    }
}
