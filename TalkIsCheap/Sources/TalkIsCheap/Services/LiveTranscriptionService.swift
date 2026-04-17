import Speech
import AVFoundation
import Foundation

/// Real-time speech preview using Apple's on-device `SFSpeechRecognizer`.
/// Produces a live-updating transcript while the user is speaking — used
/// for the cassette-overlay teleprompter. The authoritative transcription
/// still comes from Groq on release; this is only for perceived latency.
@MainActor
final class LiveTranscriptionService: ObservableObject {
    static let shared = LiveTranscriptionService()

    @Published var liveText: String = ""
    @Published var isRunning: Bool = false

    private var recognizer: SFSpeechRecognizer?
    // Accessed from the AVAudioEngine tap thread via `feed(buffer:)` — keep it
    // nonisolated so audio buffers are appended synchronously, without
    // hopping to the main actor (which would race with AVAudioEngine reusing
    // its internal buffer storage).
    private nonisolated(unsafe) var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    // MARK: - Permission

    static func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    // MARK: - Lifecycle

    func start(localeIdentifier: String?) {
        guard Self.isAuthorized else {
            Log.write("Live: speech permission not granted — skipping preview")
            return
        }

        // Pick a locale. If the user set a specific language, honour it;
        // otherwise fall back to the system default.
        let locale: Locale
        if let id = localeIdentifier, id != "auto" {
            locale = Locale(identifier: id)
        } else {
            locale = Locale.current
        }

        let rec = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        guard let rec, rec.isAvailable else {
            Log.write("Live: SFSpeechRecognizer unavailable")
            return
        }
        // Run on-device when supported — avoids any network call.
        rec.defaultTaskHint = .dictation

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }

        liveText = ""
        recognizer = rec
        request = req
        isRunning = true

        task = rec.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.liveText = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    // Task ended — we don't need to do anything here; `stop()`
                    // is driven by AudioRecorder lifecycle, not by the task.
                }
            }
        }
    }

    /// Feed a raw audio buffer (from AudioRecorder.onNativeBuffer). Called
    /// synchronously from the AVAudioEngine tap thread — we consume the
    /// buffer immediately before returning, because AVAudioEngine reuses its
    /// internal storage after the tap callback.
    /// `SFSpeechAudioBufferRecognitionRequest.append` is thread-safe and
    /// copies the audio internally, so calling it on the tap thread is fine.
    nonisolated func feed(buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func stop() {
        // Flush remaining audio so the recognizer can emit the last partial
        // result. Do NOT cancel() immediately — that would throw away the
        // tail of what the user said.
        request?.endAudio()
        isRunning = false
        // Release the task/request shortly — by then the final callback has
        // either fired or the utterance is short enough that the last partial
        // already reflects what was said.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.task?.cancel()
            self.task = nil
            self.request = nil
            self.recognizer = nil
        }
    }
}
