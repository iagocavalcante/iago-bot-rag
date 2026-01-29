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
    @Published var debugInfo: String = ""

    private var timer: Timer?
    private var lastMessageHash: Int = 0

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
            debugLog("Found: '\(contactName)' -> '\(lastMessage.prefix(50))...'")
            let messageHash = "\(contactName):\(lastMessage)".hashValue

            if messageHash != lastMessageHash {
                lastMessageHash = messageHash
                debugLog("NEW message detected from '\(contactName)'")

                let detected = DetectedMessage(
                    contactName: contactName,
                    content: lastMessage,
                    timestamp: Date()
                )

                lastDetectedMessage = detected
                onNewMessage?(detected)
            }
        } else {
            debugLog("Could not parse contact/message from WhatsApp window")
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
        // WhatsApp Desktop has two areas:
        // 1. Sidebar (chat list) - shows "Message from X" for each chat
        // 2. Main chat area - shows the active conversation
        //
        // We need the ACTIVE chat, which is identified by:
        // - Looking for the chat header (contact name at top of conversation)
        // - Finding messages in that conversation
        //
        // The active chat header appears as a clickable element with just the name
        // Messages appear with "message, <content>" prefix

        var contactName: String?
        var lastIncomingMessage: String?
        var allTexts: [(text: String, role: String, depth: Int)] = []

        // First pass: collect all text elements
        func searchElement(_ element: AXUIElement, depth: Int = 0) {
            guard depth < 15 else { return }

            let role = AccessibilityHelper.getRole(element) ?? ""
            let value = AccessibilityHelper.getValue(element)
            let title = AccessibilityHelper.getTitle(element)

            if let rawText = value ?? title, !rawText.isEmpty {
                let text = cleanText(rawText)
                allTexts.append((text, role, depth))
            }

            for child in AccessibilityHelper.getChildren(element) {
                searchElement(child, depth: depth + 1)
            }
        }

        searchElement(window)

        // Find the active chat header - it's usually a heading or button with just a name
        // that appears BEFORE the messages in the tree traversal
        // Look for AXHeading or AXStaticText that's a short name (not a message)
        for (text, role, _) in allTexts {
            // Skip sidebar items which have "Message from" prefix
            if text.hasPrefix("Message from ") { continue }
            // Skip messages
            if text.hasPrefix("message, ") || text.hasPrefix("Your message") { continue }
            // Skip UI elements
            if text.contains("WhatsApp") || text == "Chats" { continue }
            if text.hasPrefix("Ask Meta") { continue }
            if ["All", "Unread", "Favorites", "Groups"].contains(text) { continue }
            if text.contains(" of ") { continue } // "1 of 4" etc

            // Look for heading role which is typically the chat header
            if role == "AXHeading" && text.count > 1 && text.count < 50 {
                contactName = text
                break
            }
        }

        // If no heading found, try to find from "Message from" but get the FIRST one
        // (which is likely the selected/active chat)
        if contactName == nil {
            for (text, _, _) in allTexts {
                if text.hasPrefix("Message from ") {
                    let nameStart = text.index(text.startIndex, offsetBy: 13)
                    let rest = String(text[nameStart...])
                    if let commaIndex = rest.firstIndex(of: ",") {
                        contactName = String(rest[..<commaIndex])
                        break
                    }
                }
            }
        }

        // Find the LAST incoming message (most recent)
        for (text, _, _) in allTexts.reversed() {
            if text.hasPrefix("message, ") && !text.contains("Your message") {
                let msgStart = text.index(text.startIndex, offsetBy: 9)
                let content = String(text[msgStart...])
                if content.count > 1 {
                    lastIncomingMessage = content
                    break
                }
            }
        }

        // Debug: print what we found
        if contactName == nil || lastIncomingMessage == nil {
            let sample = allTexts.prefix(15).map { "[\($0.role)] \($0.text.prefix(25))" }.joined(separator: ", ")
            debugLog("Tree sample: \(sample)")
        } else {
            debugLog("Found: '\(contactName!)' -> '\(lastIncomingMessage!.prefix(50))...'")
        }

        if let name = contactName, let message = lastIncomingMessage {
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
