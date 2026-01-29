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

    /// Dump accessibility tree for debugging
    func dumpAccessibilityTree() -> String {
        guard let window = AccessibilityHelper.findWhatsAppWindow() else {
            return "WhatsApp window not found"
        }

        var output = "WhatsApp Accessibility Tree:\n"
        var allTexts: [(role: String, text: String, depth: Int)] = []

        func dumpElement(_ element: AXUIElement, depth: Int = 0) {
            guard depth < 10 else { return }

            let role = AccessibilityHelper.getRole(element) ?? "?"
            let value = AccessibilityHelper.getValue(element)
            let title = AccessibilityHelper.getTitle(element)
            let desc = AccessibilityHelper.getDescription(element)

            let text = value ?? title ?? desc
            if let t = text, !t.isEmpty {
                allTexts.append((role, t, depth))
            }

            for child in AccessibilityHelper.getChildren(element) {
                dumpElement(child, depth: depth + 1)
            }
        }

        dumpElement(window)

        // Show unique text elements found
        for (role, text, depth) in allTexts.prefix(50) {
            let indent = String(repeating: "  ", count: depth)
            let preview = String(text.prefix(60)).replacingOccurrences(of: "\n", with: "\\n")
            output += "\(indent)[\(role)] \(preview)\n"
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
        // WhatsApp Desktop accessibility structure (2024+):
        // - Contact name: AXButton with "Message from <Name>," or "<Name>,"
        // - Incoming messages: AXButton/AXStaticText starting with "message, <content>"
        // - User messages: AXButton/AXStaticText starting with "Your message, <content>"
        // NOTE: WhatsApp adds invisible Unicode markers (LTR marks) that we need to strip

        var contactName: String?
        var lastIncomingMessage: String?
        var allTexts: [(text: String, role: String)] = []

        func searchElement(_ element: AXUIElement, depth: Int = 0) {
            guard depth < 15 else { return }

            let role = AccessibilityHelper.getRole(element) ?? ""
            let value = AccessibilityHelper.getValue(element)
            let title = AccessibilityHelper.getTitle(element)

            if let rawText = value ?? title, !rawText.isEmpty {
                let text = cleanText(rawText)
                allTexts.append((text, role))

                // Extract contact name from "Message from <Name>," pattern
                if text.hasPrefix("Message from ") {
                    let nameStart = text.index(text.startIndex, offsetBy: 13) // "Message from ".count
                    let rest = String(text[nameStart...])
                    if let commaIndex = rest.firstIndex(of: ",") {
                        contactName = String(rest[..<commaIndex])
                    }
                }

                // Extract incoming message (not "Your message")
                // Format: "message, <actual message content>"
                if text.hasPrefix("message, ") && !text.contains("Your message") {
                    let msgStart = text.index(text.startIndex, offsetBy: 9) // "message, ".count
                    let content = String(text[msgStart...])
                    if content.count > 1 {
                        lastIncomingMessage = content
                    }
                }
            }

            for child in AccessibilityHelper.getChildren(element) {
                searchElement(child, depth: depth + 1)
            }
        }

        searchElement(window)

        // Debug: print what we found
        if contactName == nil || lastIncomingMessage == nil {
            let sample = allTexts.prefix(10).map { "[\($0.role)] \($0.text.prefix(30))" }.joined(separator: ", ")
            debugLog("Tree sample: \(sample)")
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
