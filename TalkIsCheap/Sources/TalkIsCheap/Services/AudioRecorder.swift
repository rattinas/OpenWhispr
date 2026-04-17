import AVFoundation
import Foundation

final class AudioRecorder: ObservableObject {
    @Published var isRecording = false

    private var audioEngine: AVAudioEngine?
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
    private let chunkInterval: TimeInterval = 1.5 // fire first chunk after 1.5s so short recordings benefit from progressive pipeline too
    private var chunkFired = false

    func start() {
        Log.write("AudioRecorder.start()")
        audioData = Data()
        chunkFired = false

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        let nativeFormat = inputNode.outputFormat(forBus: 0)
        Log.write("Native format: \(nativeFormat.sampleRate)Hz, \(nativeFormat.channelCount)ch")

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false) else {
            Log.write("Failed to create target format")
            return
        }

        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            Log.write("Failed to create audio converter")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Fan out the raw native-format buffer to consumers like SFSpeechRecognizer.
            self.onNativeBuffer?(buffer)

            let ratio = self.targetSampleRate / nativeFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return }

            var error: NSError?
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
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

        do {
            try engine.start()
            self.audioEngine = engine
            isRecording = true
            Log.write("AudioEngine started OK")

            // Schedule first chunk callback after 3 seconds
            DispatchQueue.main.async { [weak self] in
                self?.chunkTimer = Timer.scheduledTimer(withTimeInterval: self?.chunkInterval ?? 3.0, repeats: false) { [weak self] _ in
                    guard let self, self.isRecording, !self.chunkFired else { return }
                    self.chunkFired = true
                    let wav = self.createWAV(from: self.audioData, sampleRate: self.targetSampleRate)
                    Log.write("Chunk ready: \(wav.count) bytes (progressive)")
                    self.onChunkReady?(wav)
                }
            }
        } catch {
            Log.write("AudioEngine start FAILED: \(error)")
        }
    }

    func stop() -> Data {
        chunkTimer?.invalidate()
        chunkTimer = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
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
