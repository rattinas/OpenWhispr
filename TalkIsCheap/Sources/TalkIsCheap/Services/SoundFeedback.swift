import AppKit

/// Audio feedback for recording states. Honours the `soundFeedback`
/// toggle in Settings. Record-start uses our bundled cassette click
/// for brand-coherent feedback; everything else falls back to subtle
/// system sounds (Pop/Morse).
enum SoundFeedback {
    private static var enabled: Bool { AppSettings.shared.soundFeedback }

    /// Resolves and caches a custom sound from the app bundle (Resources).
    private static func loadBundled(_ name: String) -> NSSound? {
        let candidates = [
            Bundle.main.path(forResource: name, ofType: "aiff"),
            Bundle.main.resourcePath.map { $0 + "/Resources/\(name).aiff" },
        ].compactMap { $0 }
        for path in candidates {
            if FileManager.default.fileExists(atPath: path),
               let sound = NSSound(contentsOfFile: path, byReference: true) {
                return sound
            }
        }
        return nil
    }

    private static let cassetteStart: NSSound? = loadBundled("recordStart")
    private static let cassetteStop: NSSound? = loadBundled("recordStop")

    static func recordStart() {
        guard enabled else { return }
        if let click = cassetteStart {
            click.stop()
            click.play()
        } else {
            NSSound(named: "Tink")?.play()
        }
    }

    static func recordStop() {
        guard enabled else { return }
        if let click = cassetteStop {
            click.stop()
            click.play()
        } else {
            NSSound(named: "Pop")?.play()
        }
    }

    static func done() {
        guard enabled else { return }
        // Morse is a shorter, softer chirp than Glass
        NSSound(named: "Morse")?.play()
    }

    static func error() {
        guard enabled else { return }
        NSSound(named: "Basso")?.play()
    }
}
