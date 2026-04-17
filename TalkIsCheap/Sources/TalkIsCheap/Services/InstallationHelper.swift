import AppKit
import Foundation

/// First-run "Move to /Applications" flow when the app is launched from a mounted DMG.
/// Pattern: https://github.com/potionfactory/LetsMove
enum InstallationHelper {
    /// Call once early in launch. Returns true if the app is in the process of moving +
    /// relaunching from /Applications — the caller should short-circuit further startup work.
    @MainActor
    static func moveToApplicationsIfFromDMG() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        let path = bundleURL.path

        // Skip if already installed in either /Applications or ~/Applications
        if path.hasPrefix("/Applications/") { return false }
        let userApps = NSHomeDirectory() + "/Applications/"
        if path.hasPrefix(userApps) { return false }

        // Only trigger from a mounted volume (DMG / USB / network share)
        guard path.hasPrefix("/Volumes/") else { return false }

        // Ensure alert is visible even though we're an LSUIElement app
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Move TalkIsCheap to Applications?"
        alert.informativeText = "Copy the app to /Applications so Spotlight finds it and auto-updates work. I'll restart from there and walk you through setup."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Don't Move")
        alert.alertStyle = .informational

        let response = alert.runModal()
        NSApp.setActivationPolicy(.accessory)

        guard response == .alertFirstButtonReturn else { return false }

        return moveAndRelaunch(from: bundleURL)
    }

    @MainActor
    private static func moveAndRelaunch(from sourceURL: URL) -> Bool {
        let destURL = URL(fileURLWithPath: "/Applications/TalkIsCheap.app")
        let fm = FileManager.default

        // Handle existing copy in /Applications
        if fm.fileExists(atPath: destURL.path) {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            let overwrite = NSAlert()
            overwrite.messageText = "TalkIsCheap is already in Applications"
            overwrite.informativeText = "Replace the existing copy with this one?"
            overwrite.addButton(withTitle: "Replace")
            overwrite.addButton(withTitle: "Cancel")
            overwrite.alertStyle = .warning

            let resp = overwrite.runModal()
            NSApp.setActivationPolicy(.accessory)

            guard resp == .alertFirstButtonReturn else { return false }

            do {
                try fm.trashItem(at: destURL, resultingItemURL: nil)
            } catch {
                showError("Couldn't remove the existing app: \(error.localizedDescription)")
                return false
            }
        }

        do {
            try fm.copyItem(at: sourceURL, to: destURL)
        } catch {
            showError("Couldn't copy to Applications: \(error.localizedDescription)")
            return false
        }

        // Strip any quarantine flag so macOS doesn't re-prompt on first launch
        runSync("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destURL.path])

        // Eject the DMG in the background (best-effort)
        let dmgVolume = dmgVolumePath(for: sourceURL)
        if let volume = dmgVolume {
            DispatchQueue.global().async {
                _ = runSync("/usr/bin/hdiutil", ["detach", volume, "-force"])
            }
        }

        // Launch the installed copy, then terminate self
        do {
            try Process.run(
                URL(fileURLWithPath: "/usr/bin/open"),
                arguments: ["-n", destURL.path]
            )
        } catch {
            showError("Couldn't launch the moved app: \(error.localizedDescription)")
            return false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
        return true
    }

    private static func dmgVolumePath(for bundleURL: URL) -> String? {
        // Given /Volumes/TalkIsCheap/TalkIsCheap.app → /Volumes/TalkIsCheap
        let components = bundleURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else { return nil }
        return "/" + components[1...2].joined(separator: "/")
    }

    @discardableResult
    private static func runSync(_ path: String, _ args: [String]) -> Int32 {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        } catch {
            return -1
        }
    }

    @MainActor
    private static func showError(_ message: String) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Couldn't move TalkIsCheap"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
        NSApp.setActivationPolicy(.accessory)
    }
}
