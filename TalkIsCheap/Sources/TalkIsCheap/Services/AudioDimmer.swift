import Foundation
import CoreAudio

/// Dims system audio volume while recording, restores on stop.
final class AudioDimmer {
    static let shared = AudioDimmer()

    private var originalVolume: Float32?
    private let dimFactor: Float32 = 0.15 // dim to 15% of original

    func dim() {
        guard AppSettings.shared.dimAudioWhileRecording else { return }
        guard let volume = getSystemVolume() else { return }
        originalVolume = volume
        let dimmed = volume * dimFactor
        setSystemVolume(dimmed)
        Log.write("Audio dimmed: \(String(format: "%.0f", volume * 100))% → \(String(format: "%.0f", dimmed * 100))%")
    }

    func restore() {
        guard let original = originalVolume else { return }
        setSystemVolume(original)
        Log.write("Audio restored: \(String(format: "%.0f", original * 100))%")
        originalVolume = nil
    }

    // MARK: - CoreAudio

    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private func getSystemVolume() -> Float32? {
        guard let deviceID = getDefaultOutputDevice() else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        // Use kAudioDevicePropertyVolumeScalar for main volume
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0 // main channel
        )
        // Try channel 0 (main), fall back to channel 1 (left)
        var status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        if status != noErr {
            address.mElement = 1
            status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        }
        return status == noErr ? volume : nil
    }

    private func setSystemVolume(_ volume: Float32) {
        guard let deviceID = getDefaultOutputDevice() else { return }
        var vol = max(0, min(1, volume))
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0
        )
        var status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &vol)
        if status != noErr {
            // Set both channels
            address.mElement = 1
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &vol)
            address.mElement = 2
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &vol)
        }
    }
}
