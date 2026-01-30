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
        // WhatsApp Desktop message patterns (2024+):
        //
        // ACTIVE CHAT messages format:
        //   "message, <content>, <time>, Received from <Name>"
        //   "Your message, <content>, <time>, Sent to <Name>"
        //
        // SIDEBAR format (different):
        //   "Message from <Name>, <preview>"
        //
        // We want ACTIVE CHAT messages that have "Received from" at the end

        var allTexts: [(text: String, role: String)] = []

        func searchElement(_ element: AXUIElement, depth: Int = 0) {
            guard depth < 15 else { return }

            let role = AccessibilityHelper.getRole(element) ?? ""
            let value = AccessibilityHelper.getValue(element)
            let title = AccessibilityHelper.getTitle(element)

            if let rawText = value ?? title, !rawText.isEmpty {
                let text = cleanText(rawText)
                allTexts.append((text, role))
            }

            for child in AccessibilityHelper.getChildren(element) {
                searchElement(child, depth: depth + 1)
            }
        }

        searchElement(window)

        // Look for messages with "Received from <Name>" pattern (active chat messages)
        // Format: "message, <content>, <time>, Received from <Name>"
        var contactName: String?
        var lastIncomingMessage: String?

        for (text, _) in allTexts.reversed() {
            // Skip if not a received message
            guard text.hasPrefix("message, ") && text.contains("Received from ") else { continue }

            // Extract contact name from end: "Received from <Name>"
            if let receivedRange = text.range(of: "Received from ") {
                let nameStart = receivedRange.upperBound
                let name = String(text[nameStart...]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty && name.count < 50 {
                    contactName = name
                }
            }

            // Extract message content: between "message, " and the timestamp
            // Format: "message, <content>, HH:MM, Received from..."
            let afterPrefix = String(text.dropFirst(9)) // Remove "message, "

            // Find the timestamp pattern (like "20:37," or "13October2024")
            // The content is everything before the timestamp
            if let timeRange = afterPrefix.range(of: #", \d{1,2}:\d{2},"#, options: .regularExpression) {
                let content = String(afterPrefix[..<timeRange.lowerBound])
                if !content.isEmpty {
                    lastIncomingMessage = content
                }
            } else if let timeRange = afterPrefix.range(of: #", \d{1,2}\D+\d{4}"#, options: .regularExpression) {
                // Alternative date format like "13October2024"
                let content = String(afterPrefix[..<timeRange.lowerBound])
                if !content.isEmpty {
                    lastIncomingMessage = content
                }
            } else {
                // Fallback: take content before first comma-space-digit pattern
                let parts = afterPrefix.components(separatedBy: ", ")
                if parts.count > 1 {
                    lastIncomingMessage = parts[0]
                }
            }

            // Found what we need
            if contactName != nil && lastIncomingMessage != nil {
                break
            }
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

    func sendMessage(_ text: String) {
        debugLog("Attempting to send message: '\(text.prefix(30))...'")

        guard let window = AccessibilityHelper.findWhatsAppWindow() else {
            debugLog("ERROR: WhatsApp window not found for sending")
            return
        }

        // Find the text input field
        func findInputField(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
            guard depth < 15 else { return nil }

            let role = AccessibilityHelper.getRole(element)
            let desc = AccessibilityHelper.getDescription(element)

            // WhatsApp input field might be AXTextArea, AXTextField, or have specific description
            if role == "AXTextArea" || role == "AXTextField" {
                debugLog("Found input field: \(role ?? "?") desc: \(desc ?? "none")")
                return element
            }

            // Also check for contenteditable areas
            if role == "AXWebArea" || role == "AXGroup" {
                // Check children
            }

            for child in AccessibilityHelper.getChildren(element) {
                if let found = findInputField(child, depth: depth + 1) {
                    return found
                }
            }
            return nil
        }

        guard let inputField = findInputField(window) else {
            debugLog("ERROR: Could not find input field in WhatsApp")
            return
        }

        // Bring WhatsApp to front
        if let whatsApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "net.whatsapp.WhatsApp" }) {
            whatsApp.activate(options: .activateIgnoringOtherApps)
            Thread.sleep(forTimeInterval: 0.3)
        }

        debugLog("Focusing input field...")
        AccessibilityHelper.setFocus(inputField)
        Thread.sleep(forTimeInterval: 0.3)

        // Click on the input field to ensure focus
        AXUIElementPerformAction(inputField, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 0.2)

        debugLog("Pasting message via clipboard...")
        AccessibilityHelper.pasteText(text)
        Thread.sleep(forTimeInterval: 0.3)

        debugLog("Pressing Enter...")
        AccessibilityHelper.pressEnter()

        debugLog("Message send attempted")
    }
}
