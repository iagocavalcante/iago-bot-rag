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

    private func findLastMessage(in window: AXUIElement) -> (contactName: String, message: String)? {
        // This navigates the WhatsApp accessibility tree
        // The structure may vary with WhatsApp versions

        // Try to find the chat header (contact name) and message list
        var contactName: String?
        var lastMessage: String?
        var allTexts: [(text: String, role: String, depth: Int)] = []

        func searchElement(_ element: AXUIElement, depth: Int = 0) {
            guard depth < 15 else { return }

            let role = AccessibilityHelper.getRole(element) ?? ""
            let value = AccessibilityHelper.getValue(element)
            let title = AccessibilityHelper.getTitle(element)

            let text = value ?? title
            if let t = text, !t.isEmpty {
                allTexts.append((t, role, depth))
            }

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

        // Debug: print what we found
        if contactName == nil || lastMessage == nil {
            let sample = allTexts.prefix(10).map { "[\($0.role)] \($0.text.prefix(30))" }.joined(separator: ", ")
            debugLog("Tree sample: \(sample)")
        }

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
