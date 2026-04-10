import AppKit

/// System sound feedback for recording states
enum SoundFeedback {
    static func recordStart() {
        NSSound(named: "Tink")?.play()
    }

    static func recordStop() {
        NSSound(named: "Pop")?.play()
    }

    static func done() {
        NSSound(named: "Glass")?.play()
    }

    static func error() {
        NSSound(named: "Basso")?.play()
    }
}
