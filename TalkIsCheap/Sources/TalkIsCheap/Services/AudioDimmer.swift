import Foundation
import CoreAudio

/// Dims system audio volume while recording, restores on stop.
final class AudioDimmer {
    static let shared = AudioDimmer()

    private var originalVolume: Float32?
    private let dimFactor: Float32 = 0.15 // dim to 15% of original

    func dim() {
        guard AppSettings.shared.dimAudioWhileRecording else {
            Log.write("AudioDimmer: disabled in settings, skipping")
            return
        }
        guard let volume = getSystemVolume() else {
            // Fall back to AppleScript when CoreAudio won't expose the
            // volume — this happens on AirPods / some Bluetooth outputs.
            if let scripted = getVolumeViaAppleScript() {
                originalVolume = scripted
                let dimmed = max(0, min(1, scripted * dimFactor))
                setVolumeViaAppleScript(dimmed)
                Log.write("Audio dimmed (AppleScript): \(String(format: "%.0f", scripted * 100))% → \(String(format: "%.0f", dimmed * 100))%")
            } else {
                Log.write("AudioDimmer: could not read system volume via any path")
            }
            return
        }
        originalVolume = volume
        let dimmed = volume * dimFactor
        setSystemVolume(dimmed)
        Log.write("Audio dimmed: \(String(format: "%.0f", volume * 100))% → \(String(format: "%.0f", dimmed * 100))%")
    }

    func restore() {
        guard let original = originalVolume else {
            Log.write("AudioDimmer: nothing to restore")
            return
        }
        if getSystemVolume() != nil {
            setSystemVolume(original)
        } else {
            setVolumeViaAppleScript(original)
        }
        Log.write("Audio restored: \(String(format: "%.0f", original * 100))%")
        originalVolume = nil
    }

    // MARK: - AppleScript fallback (reliable on AirPods / Bluetooth)

    private func getVolumeViaAppleScript() -> Float32? {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", "output volume of (get volume settings)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let intValue = Int(str), intValue >= 0, intValue <= 100 else { return nil }
        return Float32(intValue) / 100.0
    }

    private func setVolumeViaAppleScript(_ volume: Float32) {
        let percent = Int(max(0, min(1, volume)) * 100)
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", "set volume output volume \(percent)"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
        // Detach — don't block the hotkey path waiting for osascript.
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
