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

        // ════════════════════════════════════════════════════════════════
        // HOT PATH — everything between here and `recorder.start()` eats
        // the start of the user's first word. Keep it TINY.
        // ════════════════════════════════════════════════════════════════

        // Reset state
        progressiveTask = nil
        progressiveResult = nil
        progressivePolished = nil
        self.streamingWanted = false  // will be set to true later if applicable

        // Wire the audio callback to read `streamingWanted` from self (not
        // captured by value) so we can flip it on later once we know.
        recorder.onNativeBuffer = { [weak self] buffer in
            LiveTranscriptionService.shared.feed(buffer: buffer)
            if self?.streamingWanted == true {
                StreamingTranscriber.shared.feed(buffer: buffer)
            }
        }
        recorder.onChunkReady = nil

        // START THE ENGINE — ideally <5 ms (prewarm + persistent tap + gate
        // flip). First sample lands ~21 ms after this call with our 1024-
        // frame buffer at 48 kHz.
        recorder.start()
        status = .recording

        // ════════════════════════════════════════════════════════════════
        // COLD PATH — everything below is OK to take time; audio is
        // already flowing and gets buffered by the recorder until
        // downstream consumers connect.
        // ════════════════════════════════════════════════════════════════

        EqualizerOverlay.shared.show()
        SoundFeedback.recordStart()

        // Cache frontmost app ONCE — the IPC call to WindowServer can take
        // 2-10 ms (spiking to 20-50 ms under load). Previously we called
        // it twice (once for bundle ID, once inside appAwareMode()).
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        recordingBundleId = frontmost

        let modeAtStart = appAwareMode(frontmost: frontmost) ?? settings.activePolishMode
        let modeAtStartPrompt = modeManager.allModes.first { $0.id == modeAtStart }?.prompt
        let needsStreaming = modeAtStart == "fast" && settings.shouldUseProxy && modeAtStartPrompt == nil
        // Flip the gate so the onNativeBuffer closure starts forwarding to
        // Deepgram. Any audio captured between recorder.start() and here
        // (should be <10 ms) was already buffered by StreamingTranscriber's
        // pendingAudio queue and will be sent when the WS opens.
        self.streamingWanted = needsStreaming

        // AudioDimmer can take up to ~200 ms when it falls back to
        // AppleScript on Bluetooth outputs. Off the hot path.
        Task.detached(priority: .utility) { @MainActor in
            AudioDimmer.shared.dim()
        }

        // Language pick, in order of preference:
        //   1. User explicitly set a language in Settings → use that.
        //   2. User is on "auto" → check the app-aware language store.
        //   3. No history yet → Deepgram multi-language model.
        let streamingLanguage: String?
        if settings.language != "auto" {
            streamingLanguage = settings.language
        } else if let learned = LanguagePreferenceStore.shared.languageForFrontmostApp() {
            streamingLanguage = learned
            Log.write("Auto-language: using learned '\(learned)' for frontmost app")
        } else {
            streamingLanguage = nil
        }

        LiveTranscriptionService.shared.start(
            localeIdentifier: settings.language == "auto" ? nil : settings.language
        )

        if needsStreaming {
            Task { @MainActor in
                do {
                    let token = try await ProxyClient.mintDeepgramToken()
                    StreamingTranscriber.shared.start(apiKey: token, language: streamingLanguage)
                } catch {
                    Log.write("TalkIsCheap Server token mint failed: \(error) — Apple live preview will be used as fallback")
                }
            }
        }
    }

    private var progressiveTask: Task<Void, Never>?
    private var progressiveResult: String?
    private var progressivePolished: String?

    /// Whether the current recording session is routing audio to Deepgram
    /// streaming. Read by the recorder's onNativeBuffer closure; set AFTER
    /// `recorder.start()` so the hot path stays minimal.
    private var streamingWanted = false

    /// Captured at recording-start so the language-learning store updates
    /// the RIGHT app even if the user alt-tabs after releasing the hotkey.
    private var recordingBundleId: String?

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

        // Learn language preference for this app from what the user just said
        LanguagePreferenceStore.shared.record(text: polished, bundleId: recordingBundleId)

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
        HotkeyManager.shared.resetToggleState()
        status = .ready
        EqualizerOverlay.shared.hide()
    }

    func stopAndProcess() {
        Log.write("stopAndProcess (tail capture …)")
        AudioDimmer.shared.restore()
        SoundFeedback.recordStop()

        // Keep capturing audio for a moment after the hotkey is released —
        // users typically finish the last word while the key is already
        // coming up, and macOS key events add another few tens of ms on
        // top. 200 ms is the sweet spot between "feels snappy" and "the
        // last word lands".
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms

            LiveTranscriptionService.shared.stop()
            let wavData = self.recorder.stop()
            let streamingActive = StreamingTranscriber.shared.isStreaming
            Log.write("wav size: \(wavData.count)")

            EqualizerOverlay.shared.hide()
            status = .transcribing

            Task { await self.process(wavData: wavData, streamingActive: streamingActive) }
        }
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
                // Streaming path was wanted but mint never happened. Clear
                // the audio that got buffered while we waited so it doesn't
                // leak into the next session.
                StreamingTranscriber.shared.discardPendingAudio()
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

        // Progressive pipeline is disabled — it produced truncated output
        // (only the first 1.5 s got pasted) and added cost/latency for no
        // real win. Every polish-mode dictation now does a single clean
        // transcribe → polish → paste pass.
        progressiveTask?.cancel()
        progressiveTask = nil
        progressiveResult = nil
        progressivePolished = nil

        do {
            status = .transcribing
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

    /// Whether the current search recording is also streaming via Deepgram.
    private var searchStreamingActive = false

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
        searchStreamingActive = false

        // HOT PATH: start the recorder FIRST so no first-word audio is lost.
        // Also feed audio to StreamingTranscriber so the query is ready the
        // moment the user releases (no separate Groq call needed).
        recorder.onNativeBuffer = { [weak self] buffer in
            if self?.searchStreamingActive == true {
                StreamingTranscriber.shared.feed(buffer: buffer)
            }
        }
        recorder.start()
        status = .recording

        // COLD PATH: UI + audio ducking happens after audio is flowing.
        EqualizerOverlay.shared.show()
        SoundFeedback.recordStart()
        SearchPanelManager.shared.state = .listening
        SearchPanelManager.shared.show()

        Task.detached(priority: .utility) { @MainActor in
            AudioDimmer.shared.dim()
        }

        // Mint Deepgram token and start streaming in parallel — search
        // recording benefits from the same low-latency path as fast mode.
        if settings.shouldUseProxy {
            Task { @MainActor in
                do {
                    let token = try await ProxyClient.mintDeepgramToken()
                    let lang: String? = settings.language == "auto" ? nil : settings.language
                    StreamingTranscriber.shared.start(apiKey: token, language: lang)
                    self.searchStreamingActive = true
                    Log.write("Search: Deepgram streaming started")
                } catch {
                    Log.write("Search: Deepgram token mint failed (\(error)) — will use Groq fallback")
                }
            }
        }
    }

    func stopSearchAndProcess() {
        Log.write("stopSearchAndProcess")
        AudioDimmer.shared.restore()
        SoundFeedback.recordStop()
        let wavData = recorder.stop()
        let streamingActive = searchStreamingActive
        searchStreamingActive = false
        status = .transcribing
        EqualizerOverlay.shared.hide()
        SearchPanelManager.shared.state = .searching(query: "Processing…")

        Task { await performSearch(wavData: wavData, streamingActive: streamingActive) }
    }

    private func performSearch(wavData: Data, streamingActive: Bool = false) async {
        do {
            // 1. Transcribe — use Deepgram streaming result when available
            //    (avoids a Groq round-trip and saves ~500 ms).
            let query: String
            if streamingActive {
                let streamed = await StreamingTranscriber.shared.finishAndCollect()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !streamed.isEmpty {
                    query = streamed
                    Log.write("Search: using streaming transcript (\(streamed.count) chars)")
                } else {
                    Log.write("Search: streaming empty — falling back to Groq")
                    query = try await TranscriberService.shared.transcribe(
                        wavData: wavData,
                        language: settings.language == "auto" ? nil : settings.language
                    )
                }
            } else {
                query = try await TranscriberService.shared.transcribe(
                    wavData: wavData,
                    language: settings.language == "auto" ? nil : settings.language
                )
            }

            Log.write("Search query: \(query)")

            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                SearchPanelManager.shared.showError("No speech detected")
                status = .ready
                return
            }

            // 2a. Built-in fast commands: crypto / stocks / ETFs / weather —
            //     free public APIs with no auth, sub-second answers. Runs
            //     first so "Bitcoin price?" doesn't get delegated to Brave
            //     and come back as "I don't have real-time data".
            if let instant = await BuiltInCommands.tryHandle(query: query) {
                SearchPanelManager.shared.showResult(instant)
                SoundFeedback.done()
                status = .ready
                return
            }

            // 2. Command Mode: route to a connected service when possible.
            //    This runs BEFORE the streaming web-search path — otherwise
            //    queries like "was steht in meinem Kalender" would go
            //    straight to Brave+Claude and answer "I can't access your
            //    calendar" instead of hitting Google Calendar via Pipedream.
            if AppSettings.shared.commandsUnlocked {
                await PipedreamCatalog.shared.ensureAccountsLoaded()
                let intent = IntentDetector.detect(from: query)
                let registry = ConnectorRegistry.shared
                if let connector = registry.connector(for: intent) {
                    do {
                        Log.write("Routing voice query to connector: \(connector.name)")
                        let result = try await registry.query(connector: connector, intent: intent)
                        // Flatten rawData into a text context so Claude can
                        // reason over the raw email / event / order data
                        // during follow-up chat.
                        let ctxData = (try? JSONSerialization.data(
                            withJSONObject: result.rawData,
                            options: [.prettyPrinted]
                        )).flatMap { String(data: $0, encoding: .utf8) }
                        SearchPanelManager.shared.showResult(SearchResult(
                            query: query,
                            answer: result.answer,
                            sources: [],
                            images: [],
                            widgetUrl: nil,
                            connectorId: result.connectorId,
                            connectorName: result.connectorName,
                            connectorIcon: result.icon,
                            followUpContext: ctxData,
                            pendingActions: result.pendingActions
                        ))
                        SoundFeedback.done()
                        status = .ready
                        return
                    } catch {
                        Log.write("Connector \(connector.name) error: \(error.localizedDescription) — falling back to web search")
                    }
                }
            }

            // 3. Search + Summarize — use streaming for proxy users
            if settings.shouldUseProxy {
                let language = settings.language == "auto" ? nil : settings.language
                SearchPanelManager.shared.startStreaming(query: query)
                SearchPanelManager.shared.show()

                for try await event in ProxyClient.searchStreaming(query: query, language: language) {
                    switch event {
                    case .sources(let sources, let images, let widgetUrl):
                        let searchSources = sources.map { SearchSource(title: $0.title, url: $0.url, thumbnail: nil) }
                        SearchPanelManager.shared.updateStreamingSources(sources: searchSources, images: images, widgetUrl: widgetUrl)
                    case .delta(let text):
                        SearchPanelManager.shared.appendStreamingDelta(text)
                    case .done:
                        SearchPanelManager.shared.finalizeStreaming()
                    }
                }
            } else {
                SearchPanelManager.shared.state = .searching(query: query)
                let result = try await SearchService.shared.search(query: query)
                SearchPanelManager.shared.showResult(result)
            }

            SoundFeedback.done()
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
    /// Overrides the default modes (clean, fast) only — respects manual mode choices
    /// like "professional", "marketing", or custom scenarios.
    ///
    /// Accepts an optional pre-fetched `frontmost` bundle ID so we don't
    /// IPC to WindowServer twice on the hotkey hot path.
    private func appAwareMode(frontmost: String? = nil) -> String? {
        guard settings.appAwareContext else {
            Log.write("App-aware: disabled in settings")
            return nil
        }
        let active = settings.activePolishMode
        guard active == "clean" || active == "fast" else {
            Log.write("App-aware: skipping — user explicitly picked '\(active)' mode")
            return nil
        }

        guard let bundleId = frontmost ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return nil }

        let mapping: [String: String] = [
            // Chat & Messaging → Casual
            "com.tinyspeck.slackmacgap": "casual",
            "com.apple.MobileSMS": "casual",
            "ru.keepcoder.Telegram": "casual",
            "net.whatsapp.WhatsApp": "casual",
            "com.hnc.Discord": "casual",
            "com.facebook.archon.developerID": "casual",
            "org.whispersystems.signal-desktop": "casual",
            "com.readdle.SparkMac": "email",
            "com.apple.iChat": "casual",
            "im.riot.app": "casual",

            // Email → Email
            "com.apple.mail": "email",
            "com.google.Gmail": "email",
            "com.microsoft.Outlook": "email",
            "com.readdle.smartemail-macos": "email",
            "com.airmail.airmail2": "email",
            "it.bloop.airmail3": "email",
            "com.freron.MailMate": "email",

            // IDEs & Code → Code
            "com.microsoft.VSCode": "coding",
            "com.microsoft.VSCodeInsiders": "coding",
            "com.apple.dt.Xcode": "coding",
            "com.jetbrains.intellij": "coding",
            "com.jetbrains.intellij.ce": "coding",
            "com.jetbrains.pycharm": "coding",
            "com.jetbrains.WebStorm": "coding",
            "com.jetbrains.goland": "coding",
            "com.jetbrains.rider": "coding",
            "com.jetbrains.AndroidStudio": "coding",
            "com.sublimetext.4": "coding",
            "com.sublimetext.3": "coding",
            "dev.zed.Zed": "coding",
            "dev.zed.Zed-Preview": "coding",
            "com.todesktop.230313mzl4w4u92": "coding", // Cursor
            "com.panic.Nova": "coding",
            "com.github.atom": "coding",
            "com.macromates.TextMate": "coding",
            "com.github.GitHubClient": "coding",
            "com.apple.Terminal": "coding",
            "com.googlecode.iterm2": "coding",
            "net.kovidgoyal.kitty": "coding",
            "com.mitchellh.ghostty": "coding",
            "co.zeit.hyper": "coding",
            "dev.warp.Warp-Stable": "coding",

            // Business & Docs → Professional
            "com.apple.iWork.Pages": "professional",
            "com.apple.iWork.Keynote": "professional",
            "com.apple.iWork.Numbers": "professional",
            "com.microsoft.Word": "professional",
            "com.microsoft.Powerpoint": "professional",
            "com.microsoft.Excel": "professional",
            "com.notion.id": "professional",
            "com.linear": "professional",
            "md.obsidian": "professional",
            "com.culturedcode.ThingsMac": "professional",
            "com.todoist.mac.Todoist": "professional",
            "com.apple.Notes": "professional",
            "abnerworks.Typora": "professional",
            "com.bohemiancoding.sketch3": "professional",

            // Browsers → Professional (often used for web-based writing)
            "com.google.Chrome": "professional",
            "com.google.Chrome.beta": "professional",
            "com.google.Chrome.dev": "professional",
            "com.apple.Safari": "professional",
            "org.mozilla.firefox": "professional",
            "com.microsoft.edgemac": "professional",
            "com.brave.Browser": "professional",
            "company.thebrowser.Browser": "professional", // Arc
        ]

        if let mode = mapping[bundleId] {
            Log.write("App-aware: \(bundleId) → \(mode)")
            return mode
        }

        // Fallback: fuzzy match on the bundle ID for apps we haven't explicitly
        // mapped but whose name strongly hints at a category. Helps catch
        // installer variants (beta channels, forks, VSCodium, JetBrains EAP).
        let lower = bundleId.lowercased()
        let codingHints = ["vscode", "vs-code", "xcode", "jetbrains", "cursor", "sublime", "zed", "textmate", "atom", "terminal", "iterm", "ghostty", "warp", "hyper", "kitty", "nova"]
        if codingHints.contains(where: { lower.contains($0) }) {
            Log.write("App-aware: fuzzy coding match for \(bundleId)")
            return "coding"
        }
        let chatHints = ["slack", "discord", "telegram", "whatsapp", "signal", "imessage", "messages"]
        if chatHints.contains(where: { lower.contains($0) }) {
            Log.write("App-aware: fuzzy chat match for \(bundleId)")
            return "casual"
        }
        let emailHints = ["mail", "outlook", "spark", "airmail"]
        if emailHints.contains(where: { lower.contains($0) }) {
            Log.write("App-aware: fuzzy email match for \(bundleId)")
            return "email"
        }

        Log.write("App-aware: no mapping for \(bundleId) — using default '\(active)'")
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
