import Foundation
import AVFoundation

/// Real-time streaming transcription via Deepgram's WebSocket API.
/// Audio flows OUT while the user speaks, interim + final transcripts
/// flow IN. By the time the user releases the hotkey, the transcript
/// is essentially complete — we only need to wait for the tail.
@MainActor
final class StreamingTranscriber: NSObject, ObservableObject {
    static let shared = StreamingTranscriber()

    @Published var currentTranscript: String = ""
    @Published var isStreaming: Bool = false

    private var task: URLSessionWebSocketTask?
    /// Buffers finalized utterances; partial result from current utterance
    /// is appended on top of this for display.
    private var finalizedText: String = ""
    private var lastPartial: String = ""
    /// Set once the initial sendPing pong is received, meaning the WebSocket
    /// upgrade finished and we can reliably send audio.
    private var isOpen: Bool = false
    /// Audio buffers fed before the WS connection was ready. Flushed once open.
    private var pendingAudio: [Data] = []
    private var closeContinuation: CheckedContinuation<String, Never>?

    // MARK: - Public API

    func start(apiKey: String, language: String?) {
        guard task == nil else { return }
        currentTranscript = ""
        finalizedText = ""
        lastPartial = ""
        isOpen = false
        // Do NOT clear pendingAudio here — it already holds the audio that
        // arrived BEFORE start() was called (during token mint + network).
        // Clearing would drop the first spoken word.

        // Pass the user's chosen language straight through. English-only and
        // German-only Nova-3 models are noticeably more accurate on proper
        // nouns ("Lyons", "Thursday") than the multi-language model. Only
        // fall back to "multi" when the caller couldn't determine a
        // specific language or the user explicitly wants code-switching.
        let effectiveLanguage: String
        if let language, !language.isEmpty, !["auto", "multi"].contains(language) {
            effectiveLanguage = language
        } else {
            effectiveLanguage = "multi"
        }

        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        let query: [URLQueryItem] = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "language", value: effectiveLanguage),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
        ]
        components.queryItems = query

        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let t = URLSession.shared.webSocketTask(with: request)
        task = t
        t.resume()
        isStreaming = true
        Log.write("Deepgram: connecting \(components.url?.absoluteString ?? "?")")

        // Start receiving as soon as we can — URLSessionWebSocketTask queues
        // these until the upgrade finishes.
        receiveLoop()

        // Send a ping: the pong only comes once the WebSocket is fully open,
        // which is our signal to flush queued audio.
        t.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    let ns = error as NSError
                    Log.write("Deepgram ping failed: \(ns.domain) #\(ns.code) \(error.localizedDescription)")
                    return
                }
                Log.write("Deepgram: WS open (\(self.pendingAudio.count) buffered)")
                self.isOpen = true
                // Flush any audio we captured while the upgrade was in flight.
                for data in self.pendingAudio {
                    self.task?.send(.data(data)) { err in
                        if let err { Log.write("Deepgram flush send: \(err.localizedDescription)") }
                    }
                }
                self.pendingAudio.removeAll()
            }
        }
    }

    nonisolated func feed(buffer: AVAudioPCMBuffer) {
        guard let data = Self.bufferToLinear16(buffer) else { return }
        Task { @MainActor in
            // Always buffer audio, even before the WebSocket task exists — the
            // subscriber-token mint runs in parallel with the first audio
            // frames, so the first ~200-500 ms arrives while `task` is still
            // nil. Dropping that audio was the "first word missing" bug.
            if !self.isOpen {
                self.pendingAudio.append(data)
                return
            }
            self.task?.send(.data(data)) { [weak self] error in
                if let error {
                    // If the socket has died mid-session, tear down so the
                    // next start() creates a fresh connection instead of
                    // looping on "Socket is not connected" errors forever.
                    let msg = error.localizedDescription
                    if msg.contains("Socket is not connected") || msg.contains("closed") {
                        Task { @MainActor in
                            guard let self else { return }
                            self.task?.cancel(with: .goingAway, reason: nil)
                            self.task = nil
                            self.isStreaming = false
                            self.isOpen = false
                        }
                    } else {
                        Log.write("Deepgram send error: \(msg)")
                    }
                }
            }
        }
    }

    func finishAndCollect() async -> String {
        guard let task else { return currentTranscript }

        // Flush any audio still queued from before the WS opened.
        if !isOpen && !pendingAudio.isEmpty {
            Log.write("Deepgram: flushing \(pendingAudio.count) buffers before close")
            for data in pendingAudio {
                task.send(.data(data)) { _ in }
            }
            pendingAudio.removeAll()
        }

        // Silence pad so Deepgram's VAD reliably fires the end-of-utterance
        // detector. 300 ms is enough for even a hesitating tail — the server
        // processes this as silence (no speech inference cost) so the added
        // latency is mostly the 300 ms of audio itself.
        let silenceFrames = 16000 * MemoryLayout<Int16>.size * 30 / 100 // 300 ms @ 16 kHz int16
        let silence = Data(count: silenceFrames)
        task.send(.data(silence)) { _ in }

        task.send(.string(#"{"type":"CloseStream"}"#)) { _ in }

        // Most finals arrive in 100-400 ms. 1 s is enough safety net without
        // making the user wait forever in edge cases.
        let result = await withTaskGroup(of: String.self) { group -> String in
            group.addTask { @MainActor in
                await withCheckedContinuation { cont in
                    self.closeContinuation = cont
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return ""
            }
            let first = await group.next() ?? ""
            group.cancelAll()
            return first
        }

        task.cancel(with: .normalClosure, reason: nil)
        self.task = nil
        isStreaming = false
        isOpen = false
        closeContinuation = nil

        let combined = result.isEmpty ? currentTranscript : result
        return combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isStreaming = false
        isOpen = false
        pendingAudio.removeAll()
        currentTranscript = ""
        finalizedText = ""
        lastPartial = ""
        closeContinuation?.resume(returning: "")
        closeContinuation = nil
    }

    /// Clear any pending audio that was captured before a failed mint.
    /// Called by AppState when it falls back to a different pipeline so
    /// the abandoned audio doesn't leak into the next recording.
    func discardPendingAudio() {
        pendingAudio.removeAll()
    }

    // MARK: - Receive loop

    private func receiveLoop() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                let ns = err as NSError
                Log.write("Deepgram receive error: \(ns.domain) #\(ns.code) — \(err.localizedDescription)")
                Task { @MainActor in
                    // Full tear-down so the next start() can open a fresh
                    // connection. Previously we only set isStreaming=false
                    // and left `task` dangling — the guard in start() then
                    // silently no-op'd for every subsequent dictation.
                    self.task?.cancel(with: .goingAway, reason: nil)
                    self.task = nil
                    self.isStreaming = false
                    self.isOpen = false
                    self.pendingAudio.removeAll()
                    self.closeContinuation?.resume(returning: self.currentTranscript)
                    self.closeContinuation = nil
                }
            case .success(let msg):
                switch msg {
                case .string(let text):
                    self.handle(json: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { self.handle(json: text) }
                @unknown default:
                    break
                }
                Task { @MainActor in
                    if self.task != nil { self.receiveLoop() }
                }
            }
        }
    }

    private func handle(json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let type = obj["type"] as? String ?? ""
        if type == "Results" { handleResults(obj) }
    }

    private func handleResults(_ obj: [String: Any]) {
        guard let channel = obj["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let first = alternatives.first,
              let transcript = first["transcript"] as? String
        else { return }

        let isFinal = obj["is_final"] as? Bool ?? false
        let speechFinal = obj["speech_final"] as? Bool ?? false

        Task { @MainActor in
            if isFinal {
                if !transcript.isEmpty {
                    if !self.finalizedText.isEmpty { self.finalizedText += " " }
                    self.finalizedText += transcript
                }
                self.lastPartial = ""
            } else {
                self.lastPartial = transcript
            }

            self.currentTranscript = [self.finalizedText, self.lastPartial]
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            if speechFinal, isFinal {
                self.closeContinuation?.resume(returning: self.currentTranscript)
                self.closeContinuation = nil
            }
        }
    }

    // MARK: - Audio conversion

    nonisolated private static func bufferToLinear16(_ buffer: AVAudioPCMBuffer) -> Data? {
        let targetSR = 16000.0
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSR,
            channels: 1,
            interleaved: true
        ) else { return nil }
        let converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        guard let converter else { return nil }
        let ratio = targetSR / buffer.format.sampleRate
        let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return nil }

        var error: NSError?
        var consumed = false
        converter.convert(to: out, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .endOfStream; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if error != nil { return nil }

        guard let channelData = out.int16ChannelData else { return nil }
        let frames = Int(out.frameLength)
        return Data(bytes: channelData[0], count: frames * MemoryLayout<Int16>.size)
    }
}
