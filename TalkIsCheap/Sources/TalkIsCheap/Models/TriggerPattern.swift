import Foundation
import Carbon

/// Which of the three fundamental interaction flows a TriggerPattern activates.
/// Each user can wire one pattern per mode (or turn the mode off entirely).
enum TriggerMode: String, Codable, CaseIterable, Identifiable {
    case record       // hold-to-talk dictation (push-to-talk)
    case search       // opens command mode / search panel
    case handsFree    // toggle recording (no need to hold)
    var id: String { rawValue }

    /// Human-readable title for Settings UI.
    var title: String {
        switch self {
        case .record:    return "Record"
        case .search:    return "Command Mode"
        case .handsFree: return "Hands-Free"
        }
    }

    var subtitle: String {
        switch self {
        case .record:    return "Hold to dictate, release to paste"
        case .search:    return "Open the voice search panel"
        case .handsFree: return "Toggle recording — activate with your gesture, press the key again to stop"
        }
    }

    var sfSymbol: String {
        switch self {
        case .record:    return "mic.fill"
        case .search:    return "sparkle.magnifyingglass"
        case .handsFree: return "hands.sparkles.fill"
        }
    }
}

/// Physical key that can serve as the primary trigger. We deliberately limit
/// this to modifier keys — they're globally reachable without interfering
/// with regular typing, and their CGEventFlags make detection cheap.
enum TriggerKey: String, Codable, CaseIterable, Identifiable, Hashable {
    case control
    case option
    case shift
    case command
    case function     // fn — available on MacBooks

    var id: String { rawValue }

    var label: String {
        switch self {
        case .control:  return "Control"
        case .option:   return "Option / Alt"
        case .shift:    return "Shift"
        case .command:  return "Command (⌘)"
        case .function: return "Fn"
        }
    }

    var glyph: String {
        switch self {
        case .control:  return "⌃"
        case .option:   return "⌥"
        case .shift:    return "⇧"
        case .command:  return "⌘"
        case .function: return "fn"
        }
    }

    /// Virtual key code emitted by macOS when this modifier flips state.
    /// We use this to detect which modifier caused a `.flagsChanged` event
    /// when multiple modifiers are held at once.
    var keyCode: Int {
        switch self {
        case .control:  return kVK_Control          // 0x3B (59) — also 62 for right control
        case .option:   return kVK_Option           // 0x3A (58) — also 61 for right option
        case .shift:    return kVK_Shift            // 0x38 (56)
        case .command:  return kVK_Command          // 0x37 (55) — also 54 for right cmd
        case .function: return kVK_Function         // 0x3F (63)
        }
    }

    /// Alternate left/right keycode variants, if any.
    var alternateKeyCodes: [Int] {
        switch self {
        case .control:  return [62]  // right control
        case .option:   return [61]  // right option
        case .shift:    return [60]  // right shift
        case .command:  return [54]  // right command
        case .function: return []
        }
    }

    /// True if this trigger key is currently pressed, determined from a
    /// ModifierMask snapshot.
    func isPressed(in mask: ModifierMask) -> Bool {
        switch self {
        case .control:  return mask.contains(.control)
        case .option:   return mask.contains(.option)
        case .shift:    return mask.contains(.shift)
        case .command:  return mask.contains(.command)
        case .function: return mask.contains(.function)
        }
    }
}

/// Bit-set mirror of CGEventFlags restricted to the modifiers we care about.
/// We have our own struct so HotkeyManager can work against both CGEvent and
/// NSEvent flag representations without adapters everywhere.
struct ModifierMask: OptionSet, Codable, Equatable {
    let rawValue: Int
    static let control  = ModifierMask(rawValue: 1 << 0)
    static let option   = ModifierMask(rawValue: 1 << 1)
    static let shift    = ModifierMask(rawValue: 1 << 2)
    static let command  = ModifierMask(rawValue: 1 << 3)
    static let function = ModifierMask(rawValue: 1 << 4)
}

/// Shape of the gesture that activates a mode.
enum TriggerKind: Codable, Equatable {
    /// Hold the primary key for at least `minMs` → activate.
    case hold(minMs: Int)
    /// Tap the primary key `count` times in quick succession → activate.
    case taps(count: Int)
    /// Hold the primary key AND all of `modifiers` at once → activate.
    case combo(modifiers: [TriggerKey])

    var label: String {
        switch self {
        case .hold(let ms):          return "Hold \(ms) ms"
        case .taps(let n):           return "\(n)× tap"
        case .combo(let mods):       return "+ " + mods.map(\.glyph).joined()
        }
    }

    /// Short one-line description used in Settings summary.
    func descriptionWith(primary: TriggerKey) -> String {
        switch self {
        case .hold(let ms):
            return "Hold \(primary.glyph) (\(ms) ms)"
        case .taps(let n):
            return "\(primary.glyph) × \(n)"
        case .combo(let mods):
            return ([primary] + mods).map(\.glyph).joined()
        }
    }
}

/// One user-configurable gesture that activates a single mode. Persisted as
/// JSON in `AppSettings` under the key for that mode.
struct TriggerPattern: Codable, Equatable {
    var key: TriggerKey                     // primary trigger key
    var kind: TriggerKind
    /// Maximum inter-tap gap this user consistently hits. Measured during
    /// calibration; fresh defaults use 400 ms. Only meaningful for `.taps`.
    var learnedMaxInterTapMs: Int
    /// Median inter-tap gap captured in the last calibration (just for UI display).
    var learnedMedianInterTapMs: Int
    /// Number of samples captured in the last calibration.
    var calibrationSampleCount: Int
    /// Whether this mode is active. Turning off a mode is a hard disable —
    /// the HotkeyManager won't listen for this pattern.
    var enabled: Bool

    // MARK: - Factory defaults

    static let defaultRecord = TriggerPattern(
        key: .control,
        kind: .hold(minMs: 150),
        learnedMaxInterTapMs: 400,
        learnedMedianInterTapMs: 0,
        calibrationSampleCount: 0,
        enabled: true
    )
    static let defaultSearch = TriggerPattern(
        key: .control,
        kind: .taps(count: 2),
        learnedMaxInterTapMs: 400,
        learnedMedianInterTapMs: 0,
        calibrationSampleCount: 0,
        enabled: true
    )
    // Default set chosen after user feedback during the Hotkey-rewrite beta:
    //   - Record  = Control hold (natural push-to-talk)
    //   - Search  = Control × 2 (fast, learned tolerance per user)
    //   - HandsFree = Control + Option combo (toggle — press both briefly,
    //     release, speak as long as needed, press Control again to stop)
    // HandsFree was on Ctrl+Shift originally but collided too often with
    // system shortcuts (Shift is everywhere). Opt is rarer and stays out of
    // the way of normal typing.
    static let defaultHandsFree = TriggerPattern(
        key: .control,
        kind: .combo(modifiers: [.option]),
        learnedMaxInterTapMs: 400,
        learnedMedianInterTapMs: 0,
        calibrationSampleCount: 0,
        enabled: true
    )

    static func `default`(for mode: TriggerMode) -> TriggerPattern {
        switch mode {
        case .record:    return .defaultRecord
        case .search:    return .defaultSearch
        case .handsFree: return .defaultHandsFree
        }
    }
}
