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

    private func checkForNewMessages() {
        guard let window = AccessibilityHelper.findWhatsAppWindow() else {
            if whatsAppRunning {
                debugLog("WhatsApp window not found")
            }
            whatsAppRunning = false
            return
        }
        whatsAppRunning = true

        // Find the active chat name and last message
        if let (contactName, lastMessage) = findLastMessage(in: window) {
            let messageHash = lastMessage.hashValue
            let previousHash = lastMessageHashes[contactName] ?? 0

            if messageHash != previousHash {
                lastMessageHashes[contactName] = messageHash
                debugLog("NEW from '\(contactName)': '\(lastMessage.prefix(40))...'")

                let detected = DetectedMessage(
                    contactName: contactName,
                    content: lastMessage,
                    timestamp: Date()
                )

                lastDetectedMessage = detected
                onNewMessage?(detected)
            }
            // Don't log every poll - too noisy
        } else {
            // Only log occasionally when can't parse
            debugLog("Could not parse active chat")
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

    private func findLastMessage(in window: AXUIElement) -> (contactName: String, message: String)? {
        // WhatsApp Desktop message patterns (2024+):
        //
        // ACTIVE CHAT messages format:
        //   "message, <content>, <time>, Received from <Name>"
        //   "Your message, <content>, <time>, Sent to <Name>"
        //
        // GROUP messages format:
        //   "message, <content>, <time>, <SenderName>"
        //   The group name is usually in the window/chat header
        //
        // SIDEBAR format (different):
        //   "Message from <Name>, <preview>"
        //
        // We want ACTIVE CHAT messages that have "Received from" at the end

        var allTexts: [(text: String, role: String)] = []
        var chatHeaderName: String? = nil

        func searchElement(_ element: AXUIElement, depth: Int = 0) {
            guard depth < 15 else { return }

            let role = AccessibilityHelper.getRole(element) ?? ""
            let value = AccessibilityHelper.getValue(element)
            let title = AccessibilityHelper.getTitle(element)
            let desc = AccessibilityHelper.getDescription(element)

            // Look for chat header (usually a heading or static text near the top)
            // This contains the group name or contact name for the active chat
            if role == "AXHeading" || role == "AXStaticText" {
                if let headerText = title ?? value ?? desc {
                    let cleaned = cleanText(headerText)
                    // Skip common UI elements and message content
                    let skipTexts = ["Chats", "Calls", "Updates", "Archived", "Starred",
                                     "Settings", "Search", "New Chat", "Ask Meta AI"]
                    let containsSkip = skipTexts.contains { cleaned == $0 || cleaned.hasPrefix($0) }

                    // Skip very long texts (likely message content) and very short texts
                    if cleaned.count > 1 && cleaned.count < 50 && !containsSkip &&
                       !cleaned.contains("message") && !cleaned.contains("Message") &&
                       !cleaned.contains("Received") && !cleaned.contains("Sent") &&
                       !cleaned.contains(" from ") && !cleaned.contains(" to ") {
                        // First valid heading-like element is likely the chat name
                        if chatHeaderName == nil {
                            chatHeaderName = cleaned
                            debugLog("Found chat header: '\(cleaned)'")
                        }
                    }
                }
            }

            if let rawText = value ?? title, !rawText.isEmpty {
                let text = cleanText(rawText)
                allTexts.append((text, role))
            }

            for child in AccessibilityHelper.getChildren(element) {
                searchElement(child, depth: depth + 1)
            }
        }

        searchElement(window)

        // Look for messages with patterns:
        // Active chat DM: "message, <content>, <time>, Received from <Name>"
        // Active chat Group: "message, <content> from <Sender>, <time>, Received in <GroupName>"
        // Sidebar format: "Message from <Name>, <preview>..."
        var senderName: String?
        var groupName: String?
        var lastIncomingMessage: String?
        var isGroupMessage = false

        // First: check if chat header looks like a group name (use it as primary source)
        // The header is more reliable than "Received in" which might be from a different chat
        if let header = chatHeaderName {
            // If header has group indicators or doesn't look like a person name, it's likely a group
            // Group names often have: brackets [], emojis, multiple words with special chars
            let groupIndicators = header.contains("[") || header.contains("]") ||
                                  header.contains("👥") || header.contains("🦹") ||
                                  header.count > 25
            if groupIndicators {
                groupName = header
                isGroupMessage = true
                debugLog("Using chat header as group name: '\(header)'")
            }
        }

        // Fallback: extract group name from "Received in" messages (only if no header group found)
        if groupName == nil {
            for (text, _) in allTexts {
                if text.contains("Received in ") {
                    if let receivedRange = text.range(of: "Received in ") {
                        let groupStart = receivedRange.upperBound
                        var group = String(text[groupStart...]).trimmingCharacters(in: .whitespacesAndNewlines)

                        // Remove WhatsApp status suffixes (check multiple times for multiple suffixes)
                        let suffixes = [", Pinned", ", Muted", ", Archived", ", Starred", ",Pinned", ",Muted"]
                        for _ in 0..<2 {
                            for suffix in suffixes {
                                if group.hasSuffix(suffix) {
                                    group = String(group.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                                }
                            }
                        }

                        if !group.isEmpty && group.count < 50 {
                            groupName = group
                            isGroupMessage = true
                            debugLog("Found group name from 'Received in': '\(group)'")
                            break
                        }
                    }
                }
            }
        }

        // Second pass: find actual message content
        for (text, _) in allTexts.reversed() {
            // Skip stickers, images, videos - we can't respond to these meaningfully
            if text.contains("sticker,") || text.contains("Sticker with:") ||
               text.contains("sticker from") ||
               text.contains("image,") || text.contains("video,") ||
               text.contains("Video from") || text.contains("Image from") ||
               text.contains("GIF,") || text.contains("Audio,") ||
               text.contains("Link,") {
                continue
            }

            // Skip sent messages
            if text.hasPrefix("Your message,") || text.contains("Sent to") {
                continue
            }

            // Try sidebar format first: "Message from <Name>, <content>"
            if text.hasPrefix("Message from ") {
                // Format: "Message from <Name>, <preview>..."
                let afterPrefix = String(text.dropFirst(13)) // Remove "Message from "

                // Find the first comma to split name and content
                if let commaIndex = afterPrefix.firstIndex(of: ",") {
                    var msgSender = String(afterPrefix[..<commaIndex])

                    // Clean up "Maybe " prefix that WhatsApp adds for unsaved contacts
                    if msgSender.hasPrefix("Maybe ") {
                        msgSender = String(msgSender.dropFirst(6))
                    }

                    let content = String(afterPrefix[afterPrefix.index(after: commaIndex)...])
                        .trimmingCharacters(in: .whitespaces)

                    if !msgSender.isEmpty && !content.isEmpty {
                        // If we already detected a group from first pass, use group name
                        if isGroupMessage, let group = groupName {
                            debugLog("Group sidebar (from first pass): group='\(group)', sender='\(msgSender)', msg='\(content.prefix(30))...'")
                        }
                        // If we have a chat header that differs from sender, it's likely a group
                        else if let header = chatHeaderName, header != msgSender {
                            if groupName == nil {
                                groupName = header
                            }
                            isGroupMessage = true
                            debugLog("Group sidebar: header='\(header)', sender='\(msgSender)', msg='\(content.prefix(30))...'")
                        } else {
                            senderName = msgSender
                            debugLog("DM sidebar from '\(msgSender)': '\(content.prefix(30))...'")
                        }
                        lastIncomingMessage = content
                        break
                    }
                }
                continue
            }

            // Active chat format: must start with "message, "
            guard text.hasPrefix("message, ") else { continue }

            // Check if it's a group message with "Received in"
            if text.contains("Received in ") {
                isGroupMessage = true
                // Group format: "message, <content> from <Sender>, <time>, Received in <GroupName>"
                if let receivedRange = text.range(of: "Received in ") {
                    let groupStart = receivedRange.upperBound
                    var group = String(text[groupStart...]).trimmingCharacters(in: .whitespaces)

                    // Remove WhatsApp status suffixes
                    let suffixes = [", Pinned", ", Muted", ", Archived", ", Starred"]
                    for suffix in suffixes {
                        if group.hasSuffix(suffix) {
                            group = String(group.dropLast(suffix.count))
                        }
                    }

                    if !group.isEmpty && group.count < 50 {
                        groupName = group
                        debugLog("Found group name from 'Received in': '\(group)'")
                    }
                }

                // Extract sender name from "from <Sender>," pattern before timestamp
                if let fromRange = text.range(of: " from ") {
                    let afterFrom = String(text[fromRange.upperBound...])
                    // Sender name ends at the timestamp pattern (like ", 22:26,")
                    if let commaRange = afterFrom.range(of: #", \d{1,2}:\d{2},"#, options: .regularExpression) {
                        let sender = String(afterFrom[..<commaRange.lowerBound])
                        if !sender.isEmpty {
                            debugLog("Found group sender: '\(sender)'")
                        }
                    }
                }
            }
            // Check if it's a direct message with "Received from"
            else if text.contains("Received from ") {
                // Direct message format: "message, <content>, <time>, Received from <Name>"
                if let receivedRange = text.range(of: "Received from ") {
                    let nameStart = receivedRange.upperBound
                    var name = String(text[nameStart...]).trimmingCharacters(in: .whitespaces)

                    // Remove WhatsApp status suffixes
                    let suffixes = [", Pinned", ", Muted", ", Archived", ", Starred"]
                    for suffix in suffixes {
                        if name.hasSuffix(suffix) {
                            name = String(name.dropLast(suffix.count))
                        }
                    }

                    if !name.isEmpty && name.count < 50 {
                        senderName = name
                    }
                }
            }

            // Extract message content: between "message, " and the timestamp
            let afterPrefix = String(text.dropFirst(9)) // Remove "message, "

            // Find the timestamp pattern (like "20:37," or "13October2024")
            var extractedContent: String?
            if let timeRange = afterPrefix.range(of: #", \d{1,2}:\d{2},"#, options: .regularExpression) {
                extractedContent = String(afterPrefix[..<timeRange.lowerBound])
            } else if let timeRange = afterPrefix.range(of: #", \d{1,2}\D+\d{4}"#, options: .regularExpression) {
                extractedContent = String(afterPrefix[..<timeRange.lowerBound])
            } else {
                // Fallback: take content before first comma-space-digit pattern
                let parts = afterPrefix.components(separatedBy: ", ")
                if parts.count > 1 {
                    extractedContent = parts[0]
                }
            }

            // For group messages, clean up " from <Sender>" suffix from content
            if var content = extractedContent {
                if isGroupMessage, let fromRange = content.range(of: #" from [^,]+$"#, options: .regularExpression) {
                    content = String(content[..<fromRange.lowerBound])
                }
                if !content.isEmpty {
                    lastIncomingMessage = content
                }
            }

            // Found a message
            if lastIncomingMessage != nil {
                break
            }
        }

        // Determine the contact name to use
        // For groups, use the extracted group name or chat header. For DMs, use the sender name.
        let contactName: String?
        if isGroupMessage {
            // Prefer the group name from "Received in" parsing, fallback to chat header
            if let group = groupName {
                contactName = group
                debugLog("Group message detected from 'Received in': '\(group)'")
            } else if let header = chatHeaderName {
                contactName = header
                debugLog("Group message detected, using chat header: '\(header)'")
            } else {
                contactName = nil
                debugLog("Group message detected but no group name found")
            }
        } else {
            contactName = senderName
        }

        // Debug output
        if contactName == nil || lastIncomingMessage == nil {
            let sample = allTexts.prefix(10).map { "[\($0.role)] \($0.text.prefix(40))" }.joined(separator: "\n")
            debugLog("No active chat found. Sample:\n\(sample)")
        } else {
            debugLog("Active chat: '\(contactName!)' msg: '\(lastIncomingMessage!.prefix(40))...'")
        }

        if let name = contactName, let message = lastIncomingMessage {
            return (name, message)
        }
        return nil
    }

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
