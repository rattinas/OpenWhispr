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

    /// Unified check: can the user make a transcription right now?
    /// Pro/Lifetime/Trial-with-uses → true. Otherwise → false (show paywall).
    var hasAccess: Bool {
        // Trial with remaining uses
        if settings.tier == "trial" && settings.trialUsesRemaining > 0 {
            return true
        }
        // Pro active subscription
        if (settings.tier == "pro_monthly" || settings.tier == "pro_annual")
           && settings.subscriptionStatus == "active" {
            return true
        }
        // Lifetime (legacy canUse path still works — user has own keys)
        if LicenseManager.isLicensed {
            return true
        }
        // Legacy trial fallback (old 50-use counter)
        if !LicenseManager.isLicensed && settings.remainingTrial > 0 {
            return true
        }
        return false
    }

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
        // Trial exhausted → show paywall
        if settings.shouldShowPaywall {
            NotificationCenter.default.post(name: .showPaywall, object: nil)
            SoundFeedback.error()
            return
        }

        // Check license (lifetime / pro / trial with uses remaining)
        guard hasAccess else {
            NotificationCenter.default.post(name: .showPaywall, object: nil)
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

        // Decide transcription engine based on the ACTIVE POLISH MODE:
        //   - Fast (no polish)  → Deepgram streaming for subscribers, Apple otherwise
        //   - Any polish mode   → Groq Whisper + Claude polish
        //
        // This plays to each engine's strength: Deepgram for speed, Whisper
        // for accuracy, Claude for polish. Deepgram is only used when the
        // user doesn't need polish anyway — we don't waste it on modes where
        // Whisper's better accuracy will win.
        let modeAtStart = appAwareMode() ?? settings.activePolishMode
        let modeAtStartIsFast = modeAtStart == "fast"
        let modeAtStartPrompt = modeManager.allModes.first { $0.id == modeAtStart }?.prompt
        let streamingWanted = modeAtStartIsFast && settings.shouldUseProxy && modeAtStartPrompt == nil

        let streamingLanguage: String?
        if settings.language == "auto" {
            streamingLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        } else {
            streamingLanguage = settings.language
        }

        if streamingWanted {
            Task { @MainActor in
                do {
                    let token = try await ProxyClient.mintDeepgramToken()
                    StreamingTranscriber.shared.start(apiKey: token, language: streamingLanguage)
                } catch {
                    Log.write("TalkIsCheap Server token mint failed: \(error) — Apple live preview will be used as fallback")
                }
            }
        }
        let useStreaming = streamingWanted

        recorder.onNativeBuffer = { buffer in
            LiveTranscriptionService.shared.feed(buffer: buffer)
            if useStreaming {
                StreamingTranscriber.shared.feed(buffer: buffer)
            }
        }
        LiveTranscriptionService.shared.start(
            localeIdentifier: settings.language == "auto" ? nil : settings.language
        )

        // Progressive pipeline: transcribe + polish the first 3s WHILE user still speaks.
        // Skipped when Deepgram streaming is active — the streamer already does
        // continuous transcription and the progressive path would double-bill.
        progressiveTask = nil
        progressiveResult = nil
        progressivePolished = nil
        recorder.onChunkReady = useStreaming ? nil : { [weak self] chunkWav in
            guard let self else { return }
            let modeName = self.appAwareMode() ?? self.settings.activePolishMode
            let mode = self.modeManager.allModes.first { $0.id == modeName } ?? PolishMode.builtIn[1]
            let lang = self.settings.language == "auto" ? nil : self.settings.language
            let dict = self.settings.customDictionary

            Log.write("Progressive: transcribing + polishing first chunk...")
            self.progressiveTask = Task {
                do {
                    // Step 1: Transcribe first 3 seconds
                    let rawText = try await TranscriberService.shared.transcribe(wavData: chunkWav, language: lang)
                    guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    self.progressiveResult = rawText
                    Log.write("Progressive transcribed: \(rawText.prefix(40))...")

                    // Step 2: Polish immediately (don't wait for user to release!)
                    let polished = try await PolisherService.shared.polish(text: rawText, mode: mode)
                    self.progressivePolished = polished
                    Log.write("Progressive polished: \(polished.prefix(40))... ✅ READY TO PASTE")
                } catch {
                    Log.write("Progressive pipeline failed: \(error)")
                }
            }
        }

        recorder.start()
        status = .recording
        EqualizerOverlay.shared.show()
    }

    private var progressiveTask: Task<Void, Never>?
    private var progressiveResult: String?
    private var progressivePolished: String?

    /// Shared tail of the pipeline: polish + paste + history + trial + done-status.
    /// Called with whatever raw transcript was produced — streaming (Deepgram),
    /// on-device (Apple), or cloud (Groq/Whisper).
    private func finalize(rawText: String, modeName: String, startTime: Date) async {
        status = .polishing
        let activeMode = modeManager.allModes.first { $0.id == modeName } ?? PolishMode.builtIn[1]

        // Skip polish for very short utterances in clean mode, and for the
        // "fast" mode which explicitly means no polish.
        let wordCount = rawText.split(separator: " ").count
        let skipPolish = activeMode.prompt == nil
            || (modeName == "clean" && wordCount <= 4)

        // Apple's live-preview text often has different mistakes than Whisper —
        // passing it as a second opinion helps Claude resolve ambiguous words
        // ("Entropic" in Whisper vs "Anthropic" in Apple) using the intersection
        // of both transcripts. Only include if it's meaningfully different.
        let live = LiveTranscriptionService.shared.liveText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let liveHint = (!live.isEmpty && live != rawText && live.count > 5)
            ? live : nil

        let polishStart = Date()
        let polished: String
        if skipPolish {
            Log.write("Polish: skipped (mode=\(modeName), \(wordCount)w)")
            polished = rawText
        } else {
            Log.write("Polish: running (mode=\(modeName), \(wordCount)w\(liveHint != nil ? ", + live-hint" : "")) …")
            do {
                polished = try await PolisherService.shared.polish(text: rawText, mode: activeMode, altTranscript: liveHint)
                let polishDur = Date().timeIntervalSince(polishStart)
                Log.write("Polish: done in \(String(format: "%.2f", polishDur))s, \(polished.count) chars")
            } catch {
                Log.write("Polish: failed \(error) — using raw text")
                polished = rawText
            }
        }

        PasteService.paste(polished)

        let duration = Date().timeIntervalSince(startTime)
        let finalWordCount = polished.split(separator: " ").count
        history.add(raw: rawText, polished: polished, mode: modeName, duration: duration)
        if !LicenseManager.isLicensed && settings.tier != "pro_monthly" && settings.tier != "pro_annual" {
            settings.trialUses += 1
        }
        SoundFeedback.done()
        status = .done(wordCount: finalWordCount, duration: duration)
        Log.write("Done: \(finalWordCount)w in \(String(format: "%.2f", duration))s")
        hideOverlayAfterDelay()
    }

    func cancelRecording() {
        guard case .recording = status else { return }
        Log.write("cancelRecording (short tap)")
        progressiveTask?.cancel()
        progressiveTask = nil
        progressiveResult = nil
        progressivePolished = nil
        LiveTranscriptionService.shared.stop()
        StreamingTranscriber.shared.cancel()
        _ = recorder.stop()
        AudioDimmer.shared.restore()
        status = .ready
        EqualizerOverlay.shared.hide()
    }

    func stopAndProcess() {
        Log.write("stopAndProcess")
        AudioDimmer.shared.restore()
        SoundFeedback.recordStop()
        LiveTranscriptionService.shared.stop()
        let wavData = recorder.stop()
        let streamingActive = StreamingTranscriber.shared.isStreaming
        Log.write("wav size: \(wavData.count)")

        // Hide overlay immediately for speed perception
        EqualizerOverlay.shared.hide()
        status = .transcribing

        Task { await process(wavData: wavData, streamingActive: streamingActive) }
    }

    private func process(wavData: Data, streamingActive: Bool = false) async {
        let startTime = Date()
        let modeName = appAwareMode() ?? settings.activePolishMode
        let activeMode = modeManager.allModes.first { $0.id == modeName } ?? PolishMode.builtIn[1]
        let isFastMode = activeMode.prompt == nil
        let wavBytes = wavData.count
        let approxSeconds = Double(wavBytes) / (16000 * 4)

        // ⚡ FAST MODE — no polish. Use Deepgram's streamed transcript if we
        // have one (subscriber path), otherwise Apple's live-preview text
        // (BYOK/offline path). Paste immediately.
        if isFastMode {
            let text: String
            if streamingActive {
                Log.write("⚡ FAST/stream: finalizing Deepgram transcript…")
                let streamed = await StreamingTranscriber.shared.finishAndCollect()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !streamed.isEmpty {
                    text = streamed
                } else {
                    // Stream produced nothing — fall back to Apple live text
                    text = LiveTranscriptionService.shared.liveText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    Log.write("⚡ FAST/stream empty → Apple fallback (\(text.count) chars)")
                }
            } else {
                text = LiveTranscriptionService.shared.liveText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                Log.write("⚡ FAST/apple: \(text.count) chars")
            }

            progressiveTask = nil
            progressiveResult = nil
            progressivePolished = nil

            guard !text.isEmpty else {
                status = .error("No speech detected")
                SoundFeedback.error()
                hideOverlayAfterDelay()
                return
            }
            await finalize(rawText: text, modeName: modeName, startTime: startTime)
            return
        }

        // --- All polish modes below: Groq Whisper + Claude polish ---

        do {
            // ⚡ FAST PATH: If progressive pipeline already polished the text → paste IMMEDIATELY
            if let polished = progressivePolished, !polished.isEmpty, approxSeconds <= 5.0 {
                let rawText = progressiveResult ?? polished
                Log.write("⚡ INSTANT PASTE (progressive pipeline ready, \(String(format: "%.1f", approxSeconds))s)")

                PasteService.paste(polished)

                let duration = Date().timeIntervalSince(startTime)
                let wordCount = polished.split(separator: " ").count
                history.add(raw: rawText, polished: polished, mode: modeName, duration: duration)
                if !LicenseManager.isLicensed && settings.tier != "pro_monthly" && settings.tier != "pro_annual" {
                    settings.trialUses += 1
                }
                SoundFeedback.done()
                status = .done(wordCount: wordCount, duration: duration)
                Log.write("Done: \(wordCount)w in \(String(format: "%.2f", duration))s (instant!)")
                hideOverlayAfterDelay()

                progressiveTask = nil
                progressiveResult = nil
                progressivePolished = nil
                return
            }

            // Show "polishing" while we process — no early-paste (that caused duplicates).
            // The progressive transcription we started during recording is still useful:
            // by the time the user releases, the first chunk's transcribe+polish is often
            // already done, so the final call is much faster.
            if progressivePolished != nil && approxSeconds > 5.0 {
                Log.write("Progressive chunk ready, finalizing full text…")
                status = .polishing
            }

            // Transcribe full audio for accuracy
            Log.write("Transcribing full \(String(format: "%.1f", approxSeconds))s (mode=\(modeName))…")
            let rawText = try await TranscriberService.shared.transcribe(
                wavData: wavData,
                language: settings.language == "auto" ? nil : settings.language,
                polishMode: modeName
            )
            progressiveTask = nil
            progressiveResult = nil
            progressivePolished = nil
            Log.write("RAW: \(rawText.prefix(80))...")

            guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                status = .error("No speech detected")
                SoundFeedback.error()
                hideOverlayAfterDelay()
                return
            }

            // Polish — but skip for very short transcripts on "clean" mode to save 500-1000ms.
            // For casual short phrases ("Hallo wie geht's"), polish barely changes anything and
            // the perceived speed win matters more than the formatting touch-ups.
            let wordCount = rawText.split(separator: " ").count
            let shouldSkipPolish = modeName == "clean" && wordCount <= 4

            Log.write("Polishing [\(modeName)]... \(shouldSkipPolish ? "(skipped — short text)" : "")")
            status = .polishing
            let activeMode = modeManager.allModes.first { $0.id == modeName } ?? PolishMode.builtIn[1]

            let polished: String
            if shouldSkipPolish {
                polished = rawText
            } else {
                do {
                    polished = try await PolisherService.shared.polish(text: rawText, mode: activeMode)
                } catch {
                    // If polishing fails, use raw text
                    Log.write("Polish failed: \(error), using raw text")
                    polished = rawText
                }
            }
            Log.write("POLISHED: \(polished.prefix(80))...")

            // Paste
            PasteService.paste(polished)

            // Track
            let duration = Date().timeIntervalSince(startTime)
            let finalWordCount = polished.split(separator: " ").count

            history.add(raw: rawText, polished: polished, mode: modeName, duration: duration)

            if !LicenseManager.isLicensed {
                settings.trialUses += 1
            }

            SoundFeedback.done()
            status = .done(wordCount: finalWordCount, duration: duration)
            Log.write("Done: \(finalWordCount)w in \(String(format: "%.1f", duration))s")
            hideOverlayAfterDelay()

        } catch let err as ProxyClient.ProxyError {
            Log.write("PROXY ERROR: \(err)")
            SoundFeedback.error()
            switch err {
            case .paymentRequired:
                status = .error("Trial used up — opening paywall…")
                NotificationCenter.default.post(name: .showPaywall, object: nil)
            case .quotaExceeded(_, let limit, _, _):
                status = .error("Monthly limit \(limit) reached — upgrade")
                NotificationCenter.default.post(name: .showPaywall, object: nil)
            case .unauthorized:
                status = .error("License invalid — reactivate in Settings")
            case .networkError:
                status = .error("No internet — check connection")
            case .serverError(let msg):
                status = .error(String(msg.prefix(50)))
            }
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
        if settings.shouldShowPaywall {
            NotificationCenter.default.post(name: .showPaywall, object: nil)
            SoundFeedback.error()
            return
        }
        guard hasAccess else {
            NotificationCenter.default.post(name: .showPaywall, object: nil)
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
