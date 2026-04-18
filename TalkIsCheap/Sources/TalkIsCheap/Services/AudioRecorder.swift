import AVFoundation
import Foundation

/// Audio recorder built for *minimum* hotkey-to-first-sample latency.
///
/// Design:
/// - The AVAudioEngine is built ONCE (lazily on first `prewarm()`).
/// - The input tap is installed ONCE and stays installed for the app's
///   lifetime. A `isCapturing` gate flag controls whether tapped buffers
///   accumulate or get discarded.
/// - `start()` flips the gate on and resumes the engine (~10-40 ms warm)
///   instead of cold-starting it (~70-200 ms).
/// - `stop()` flips the gate off and pauses the engine so the macOS mic
///   indicator turns off between dictations (privacy) — but all the slow
///   setup (HAL spin-up, format negotiation, converter build, tap install)
///   only happens ONCE.
///
/// Net effect: first audio sample arrives ~20-40 ms after the hotkey
/// instead of ~150-400 ms on the cold path.
final class AudioRecorder: ObservableObject {
    @Published var isRecording = false

    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var nativeFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    private var tapInstalled = false

    /// Gate flag: when false, tapped buffers are discarded. Flipped on by
    /// start(), off by stop(). Cheap and race-free (bool reads/writes are
    /// atomic on x86/arm64).
    private var isCapturing = false

    private var audioData = Data()
    private let targetSampleRate: Double = 16000

    /// Callback fired every `chunkInterval` seconds with the WAV data so far.
    /// Used for progressive transcription (Spotify-style pre-loading).
    var onChunkReady: ((Data) -> Void)?
    /// Called for each raw PCM buffer at native sample rate. Consumers like
    /// `LiveTranscriptionService` (Apple SFSpeechRecognizer) use this for
    /// real-time preview without doing their own audio capture.
    var onNativeBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var chunkTimer: Timer?
    private let chunkInterval: TimeInterval = 1.5
    private var chunkFired = false

    /// Build the engine and install the tap. Safe to call multiple times;
    /// idempotent. Call at app launch to move ALL the expensive setup off
    /// the hotkey hot path.
    func prewarm() {
        if audioEngine != nil && tapInstalled {
            return
        }

        Log.write("AudioRecorder.prewarm() — building persistent engine")

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        let nativeFormat = inputNode.outputFormat(forBus: 0)
        Log.write("Native format: \(nativeFormat.sampleRate)Hz, \(nativeFormat.channelCount)ch")

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            Log.write("prewarm: failed to build target format")
            return
        }

        guard let conv = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            Log.write("prewarm: failed to build converter")
            return
        }

        // Smaller buffer size = lower first-sample latency. 1024 frames at
        // 48 kHz ≈ 21 ms per callback vs. 4096 frames ≈ 85 ms. CPU cost is
        // negligible at this rate (a few fused-multiply-adds per sample).
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Gate: drop buffers while not recording. Cheapest possible
            // no-op path for the "not recording" state so pre-warming is
            // essentially free.
            guard self.isCapturing else { return }

            // Fan out the raw native-format buffer to consumers like SFSpeechRecognizer.
            self.onNativeBuffer?(buffer)

            let ratio = self.targetSampleRate / nativeFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return }

            var error: NSError?
            self.converter?.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let err = error {
                Log.write("Convert error: \(err)")
                return
            }

            if let channelData = outputBuffer.floatChannelData {
                let frames = Int(outputBuffer.frameLength)
                let data = Data(bytes: channelData[0], count: frames * MemoryLayout<Float>.size)
                self.audioData.append(data)
            }
        }

        // Tell CoreAudio to pre-allocate buffers. First actual start() is
        // much faster after prepare().
        engine.prepare()

        self.audioEngine = engine
        self.converter = conv
        self.nativeFormat = nativeFormat
        self.targetFormat = targetFormat
        self.tapInstalled = true

        Log.write("AudioRecorder prewarm complete (tap installed, engine prepared)")
    }

    func start() {
        // Ensure the engine exists — in case prewarm() wasn't called yet.
        if audioEngine == nil || !tapInstalled {
            prewarm()
        }
        guard let engine = audioEngine else {
            Log.write("AudioRecorder.start: no engine")
            return
        }

        audioData = Data()
        chunkFired = false

        // Flip the gate BEFORE starting the engine. Any buffers already in
        // flight from a still-running engine will be captured immediately.
        isCapturing = true

        if !engine.isRunning {
            do {
                try engine.start()
                Log.write("AudioEngine started (warm)")
            } catch {
                Log.write("AudioEngine start FAILED: \(error)")
                isCapturing = false
                return
            }
        } else {
            Log.write("AudioEngine already running — instant capture")
        }

        isRecording = true

        // Schedule first chunk callback after 1.5 seconds — progressive
        // transcription hook (currently disabled but kept for future use).
        DispatchQueue.main.async { [weak self] in
            self?.chunkTimer = Timer.scheduledTimer(withTimeInterval: self?.chunkInterval ?? 1.5, repeats: false) { [weak self] _ in
                guard let self, self.isRecording, !self.chunkFired else { return }
                self.chunkFired = true
                let wav = self.createWAV(from: self.audioData, sampleRate: self.targetSampleRate)
                Log.write("Chunk ready: \(wav.count) bytes (progressive)")
                self.onChunkReady?(wav)
            }
        }
    }

    func stop() -> Data {
        chunkTimer?.invalidate()
        chunkTimer = nil

        // Flip the gate off FIRST so no further buffers are captured.
        isCapturing = false

        // Pause the engine (not full stop + teardown) so the next start()
        // can resume quickly AND the macOS mic indicator turns off between
        // dictations. The tap stays installed for the engine's lifetime.
        audioEngine?.pause()

        isRecording = false
        Log.write("AudioRecorder stopped, pcm bytes: \(audioData.count)")
        return createWAV(from: audioData, sampleRate: targetSampleRate)
    }

    /// Get current WAV snapshot without stopping
    func currentWAV() -> Data {
        return createWAV(from: audioData, sampleRate: targetSampleRate)
    }

    private func createWAV(from pcmData: Data, sampleRate: Double) -> Data {
        var wav = Data()
        let dataSize = UInt32(pcmData.count)
        let fileSize = UInt32(36 + dataSize)
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 32
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let sr = UInt32(sampleRate)
        let audioFormat: UInt16 = 3 // IEEE float

        wav.append(contentsOf: "RIFF".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: sr.littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        wav.append(contentsOf: "data".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        wav.append(pcmData)

        return wav
    }
}
