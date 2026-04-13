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
        guard AXIsProcessTrusted() else { return false }

        let vKeyCode: CGKeyCode = 0x09 // 'V' key

        guard let cmdDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let cmdUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        else { return false }

        cmdDown.flags = .maskCommand
        cmdUp.flags = .maskCommand

        cmdDown.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)

        return true
    }
}
