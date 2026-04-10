import AVFoundation
import Foundation

final class AudioRecorder: ObservableObject {
    @Published var isRecording = false

    private var audioEngine: AVAudioEngine?
    private var audioData = Data()
    private let targetSampleRate: Double = 16000

    func start() {
        Log.write("AudioRecorder.start()")
        audioData = Data()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Use the input node's NATIVE format — don't force a custom one
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        Log.write("Native format: \(nativeFormat.sampleRate)Hz, \(nativeFormat.channelCount)ch")

        // Target format: 16kHz mono float32 for Whisper
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false) else {
            Log.write("Failed to create target format")
            return
        }

        // Create converter from native → 16kHz mono
        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            Log.write("Failed to create audio converter")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Calculate output frame count
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
        } catch {
            Log.write("AudioEngine start FAILED: \(error)")
        }
    }

    func stop() -> Data {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false
        Log.write("AudioRecorder stopped, pcm bytes: \(audioData.count)")
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
