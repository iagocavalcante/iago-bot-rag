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

    static func isSelected(_ element: AXUIElement) -> Bool {
        getElementValue(element, attribute: kAXSelectedAttribute as String) as? Bool ?? false
    }

    static func isFocused(_ element: AXUIElement) -> Bool {
        getElementValue(element, attribute: kAXFocusedAttribute as String) as? Bool ?? false
    }

    static func getIdentifier(_ element: AXUIElement) -> String? {
        getElementValue(element, attribute: kAXIdentifierAttribute as String) as? String
    }

    static func setFocus(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)
    }

    /// Set the value of a text field directly via accessibility (no focus required)
    static func setValue(_ element: AXUIElement, value: String) -> Bool {
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        return result == .success
    }

    /// Click a button element via accessibility action
    static func clickElement(_ element: AXUIElement) -> Bool {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return result == .success
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

    /// Press Enter key - posts directly to WhatsApp process (works without focus)
    static func pressEnter() {
        guard let whatsApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "net.whatsapp.WhatsApp" }) else {
            print("WhatsApp not running")
            return
        }

        let pid = whatsApp.processIdentifier

        // Post CGEvent directly to WhatsApp's PID (works without focus)
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true) // 36 = Return
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)

        keyDown?.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.05)
        keyUp?.postToPid(pid)

        print("Enter key posted to WhatsApp PID \(pid)")
    }

    /// Copy text to clipboard and paste (more reliable than typing)
    static func pasteText(_ text: String) {
        // Save current clipboard
        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)

        // Copy our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Get WhatsApp's process ID
        let pid = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "net.whatsapp.WhatsApp" })?
            .processIdentifier

        // Cmd+V to paste
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9 // 'v' key

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        if let pid = pid {
            keyDown?.postToPid(pid)
            keyUp?.postToPid(pid)
        } else {
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }

        // Restore old clipboard after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let old = oldContents {
                pasteboard.clearContents()
                pasteboard.setString(old, forType: .string)
            }
        }
    }
}
