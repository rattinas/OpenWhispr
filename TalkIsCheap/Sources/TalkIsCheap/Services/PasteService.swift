import Cocoa
import UserNotifications

/// Paste text at the cursor position
enum PasteService {
    static func paste(_ text: String) {
        // Always copy to clipboard first
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Log.write("PasteService: text copied to clipboard")

        // Small delay to ensure clipboard is ready
        usleep(50_000)

        // Try CGEvent-based Cmd+V (works if Accessibility is granted)
        if simulatePaste() {
            Log.write("PasteService: auto-paste OK (CGEvent)")
            return
        }

        // Fallback: AppleScript
        let script = NSAppleScript(source: """
            tell application "System Events"
                keystroke "v" using command down
            end tell
        """)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)

        if error == nil {
            Log.write("PasteService: auto-paste OK (AppleScript)")
            return
        }

        // Both methods failed — notify user
        Log.write("PasteService: auto-paste failed, text is in clipboard")
        DispatchQueue.main.async {
            let content = UNMutableNotificationContent()
            content.title = "TalkIsCheap"
            content.body = "Text copied — press Cmd+V to paste"
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { _ in }
        }
    }

    /// Simulate Cmd+V using CGEvent (requires Accessibility permission)
    private static func simulatePaste() -> Bool {
        return sendCmdKey(virtualKey: 0x09) // 'V'
    }

    /// Undo the previous paste (Cmd+Z) before pasting `text`. Used when a
    /// progressive early-paste needs to be replaced by the final full text
    /// without leaving a duplicate in the target field.
    static func replacePreviousPaste(with text: String) {
        // Undo the previous paste
        _ = sendCmdKey(virtualKey: 0x06) // 'Z'
        usleep(40_000)
        paste(text)
    }

    @discardableResult
    private static func sendCmdKey(virtualKey: CGKeyCode) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
