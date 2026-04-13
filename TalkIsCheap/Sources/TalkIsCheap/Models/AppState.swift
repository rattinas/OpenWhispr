import SwiftUI
import Combine
import UserNotifications
import AppKit

/// Central app state
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Status: Equatable {
        case loading
        case ready
        case recording
        case transcribing
        case polishing
        case done(wordCount: Int, duration: Double)
        case error(String)
    }

    @Published var status: Status = .loading
    @Published var showOnboarding = false
    @Published var showSettings = false

    let recorder = AudioRecorder()
    let settings = AppSettings.shared
    let modeManager = PolishModeManager.shared
    let history = TranscriptionHistory.shared

    var menuBarIcon: String {
        switch status {
        case .recording: return "mic.fill"
        case .transcribing, .polishing, .loading: return "ellipsis.circle"
        case .error: return "exclamationmark.triangle"
        default: return "mic"
        }
    }

    var statusText: String {
        switch status {
        case .loading: return "Loading..."
        case .ready: return "Ready — hold your hotkey to dictate"
        case .recording:
            if HotkeyManager.shared.isHandsFree { return "🎙 Hands-free — release to stop" }
            return "Recording..."
        case .transcribing: return "Transcribing..."
        case .polishing: return "Polishing..."
        case .done(let words, let duration): return "✅ \(words) words in \(String(format: "%.1f", duration))s"
        case .error(let msg): return "⚠️ \(msg)"
        }
    }

    func startRecording() {
        // Check license
        guard LicenseManager.canUse else {
            status = .error("Trial expired — buy license in menu bar")
            SoundFeedback.error()
            return
        }

        // Check mic permission
        guard PermissionManager.micPermissionGranted else {
            PermissionManager.requestMicPermission { [weak self] granted in
                if granted {
                    self?.startRecording()
                } else {
                    self?.status = .error("Microphone access denied")
                    PermissionManager.openMicSettings()
                }
            }
            return
        }

        Log.write("startRecording")
        AudioDimmer.shared.dim()
        SoundFeedback.recordStart()
        recorder.start()
        status = .recording
        EqualizerOverlay.shared.show()
    }

    func cancelRecording() {
        guard case .recording = status else { return }
        Log.write("cancelRecording (short tap)")
        _ = recorder.stop()
        AudioDimmer.shared.restore()
        status = .ready
        EqualizerOverlay.shared.hide()
    }

    func stopAndProcess() {
        Log.write("stopAndProcess")
        AudioDimmer.shared.restore()
        SoundFeedback.recordStop()
        let wavData = recorder.stop()
        Log.write("wav size: \(wavData.count)")
        status = .transcribing

        Task { await process(wavData: wavData) }
    }

    private func process(wavData: Data) async {
        let startTime = Date()
        let modeName = appAwareMode() ?? settings.activePolishMode

        do {
            // Transcribe
            Log.write("Transcribing...")
            let rawText = try await TranscriberService.shared.transcribe(
                wavData: wavData,
                language: settings.language == "auto" ? nil : settings.language
            )
            Log.write("RAW: \(rawText.prefix(80))...")

            guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                status = .error("No speech detected")
                SoundFeedback.error()
                hideOverlayAfterDelay()
                return
            }

            // Polish
            Log.write("Polishing [\(modeName)]...")
            status = .polishing
            let activeMode = modeManager.allModes.first { $0.id == modeName } ?? PolishMode.builtIn[1]

            let polished: String
            do {
                polished = try await PolisherService.shared.polish(text: rawText, mode: activeMode)
            } catch {
                // If polishing fails, use raw text
                Log.write("Polish failed: \(error), using raw text")
                polished = rawText
            }
            Log.write("POLISHED: \(polished.prefix(80))...")

            // Paste
            PasteService.paste(polished)

            // Track
            let duration = Date().timeIntervalSince(startTime)
            let wordCount = polished.split(separator: " ").count

            history.add(raw: rawText, polished: polished, mode: modeName, duration: duration)

            if !LicenseManager.isLicensed {
                settings.trialUses += 1
            }

            SoundFeedback.done()
            status = .done(wordCount: wordCount, duration: duration)
            Log.write("Done: \(wordCount)w in \(String(format: "%.1f", duration))s")
            hideOverlayAfterDelay()

        } catch {
            Log.write("ERROR: \(error)")
            SoundFeedback.error()

            // Copy error info and try to help
            let errorMsg = error.localizedDescription
            if errorMsg.contains("API") || errorMsg.contains("key") {
                status = .error("API error — check your keys in Settings")
            } else if errorMsg.contains("network") || errorMsg.contains("connection") {
                status = .error("No internet — check connection")
            } else {
                status = .error(String(errorMsg.prefix(50)))
            }
            hideOverlayAfterDelay()
        }
    }

    // MARK: - Voice Search (Ctrl+Cmd)

    func startSearchRecording() {
        guard LicenseManager.canUse else {
            status = .error("Trial expired — buy license in menu bar")
            SoundFeedback.error()
            return
        }

        Log.write("startSearchRecording")
        AudioDimmer.shared.dim()
        SoundFeedback.recordStart()
        recorder.start()
        status = .recording
        EqualizerOverlay.shared.show()
        SearchPanelManager.shared.state = .listening
        SearchPanelManager.shared.show()
    }

    func stopSearchAndProcess() {
        Log.write("stopSearchAndProcess")
        AudioDimmer.shared.restore()
        SoundFeedback.recordStop()
        let wavData = recorder.stop()
        status = .transcribing
        EqualizerOverlay.shared.hide()
        SearchPanelManager.shared.state = .searching(query: "Processing...")

        Task { await performSearch(wavData: wavData) }
    }

    private func performSearch(wavData: Data) async {
        do {
            // 1. Transcribe
            let query = try await TranscriberService.shared.transcribe(
                wavData: wavData,
                language: settings.language == "auto" ? nil : settings.language
            )
            Log.write("Search query: \(query)")

            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                SearchPanelManager.shared.showError("No speech detected")
                status = .ready
                return
            }

            // 2. Search + Summarize
            SearchPanelManager.shared.state = .searching(query: query)
            let result = try await SearchService.shared.search(query: query)

            // 3. Show result
            SoundFeedback.done()
            SearchPanelManager.shared.showResult(result)
            status = .ready

        } catch {
            Log.write("Search error: \(error)")
            SoundFeedback.error()
            SearchPanelManager.shared.showError(error.localizedDescription)
            status = .ready
        }
    }

    // MARK: - App-Aware Context

    /// Returns a polish mode ID based on the frontmost app, or nil to use the user's selected mode.
    /// Only overrides when the user has "clean" (default) selected — respects manual mode choices.
    private func appAwareMode() -> String? {
        guard settings.appAwareContext else { return nil }
        guard settings.activePolishMode == "clean" else { return nil }

        guard let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return nil }

        let mapping: [String: String] = [
            // Chat & Messaging → Casual
            "com.tinyspeck.slackmacgap": "casual",
            "com.apple.MobileSMS": "casual",
            "ru.keepcoder.Telegram": "casual",
            "net.whatsapp.WhatsApp": "casual",
            "com.hnc.Discord": "casual",
            "com.facebook.archon.developerID": "casual",

            // Email → Email
            "com.apple.mail": "email",
            "com.google.Gmail": "email",
            "com.microsoft.Outlook": "email",
            "com.readdle.smartemail-macos": "email",

            // IDEs & Code → Code
            "com.microsoft.VSCode": "coding",
            "com.apple.dt.Xcode": "coding",
            "com.jetbrains.intellij": "coding",
            "com.sublimetext.4": "coding",
            "dev.zed.Zed": "coding",
            "com.todesktop.230313mzl4w4u92": "coding", // Cursor

            // Business & Docs → Professional
            "com.apple.iWork.Pages": "professional",
            "com.apple.iWork.Keynote": "professional",
            "com.microsoft.Word": "professional",
            "com.microsoft.Powerpoint": "professional",
            "com.google.Chrome": "professional",
            "com.notion.id": "professional",
            "com.linear": "professional",
        ]

        if let mode = mapping[bundleId] {
            Log.write("App-aware: \(bundleId) → \(mode)")
            return mode
        }
        return nil
    }

    private func hideOverlayAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            EqualizerOverlay.shared.hide()
            try? await Task.sleep(for: .seconds(4))
            if case .done = status { status = .ready }
            if case .error = status { status = .ready }
        }
    }
}
