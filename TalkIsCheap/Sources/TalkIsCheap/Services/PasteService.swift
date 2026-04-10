import Cocoa

/// Paste text at the cursor position
enum PasteService {
    static func paste(_ text: String) {
        // Always copy to clipboard first
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Log.write("PasteService: text copied to clipboard")

        // Try AppleScript paste
        let script = NSAppleScript(source: """
            tell application "System Events"
                keystroke "v" using command down
            end tell
        """)

        usleep(50_000)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)

        if let error = error {
            Log.write("PasteService: auto-paste failed, text is in clipboard. Error: \(error["NSAppleScriptErrorBriefMessage"] ?? "")")
            // Show notification — user can Cmd+V
            DispatchQueue.main.async {
                let notification = NSUserNotification()
                notification.title = "TalkIsCheap"
                notification.informativeText = "Text copied — press Cmd+V to paste"
                notification.soundName = nil
                NSUserNotificationCenter.default.deliver(notification)
            }
        } else {
            Log.write("PasteService: auto-paste OK")
        }
    }
}
