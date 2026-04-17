import Foundation
import AppKit
import NaturalLanguage

/// Per-app language preferences learned from what the user actually says.
///
/// Each time a dictation completes, we run Apple's NLLanguageRecognizer on
/// the final text and update the preference for the app the user was
/// typing into. On the next dictation in the same app we use the learned
/// language as the Deepgram hint — which beats the multi-language model
/// on proper nouns (Lyons vs Lions, Thursday vs first day).
@MainActor
final class LanguagePreferenceStore {
    static let shared = LanguagePreferenceStore()

    private let storeKey = "appLanguagePreferences.v1"
    private let minConfidence: Double = 0.75
    private let maxSampleCount = 20

    private struct Entry: Codable {
        // ISO language code: "en", "de", "fr", etc.
        var code: String
        // Simple smoothing: how many samples back this pref is based on.
        var sampleCount: Int
        var lastUpdated: Date
    }

    private var entries: [String: Entry] = [:]

    init() { load() }

    // MARK: - Lookup

    /// Return the best language code to use for the given bundle id. Returns
    /// nil when we have no data — callers should fall back to `multi`.
    func language(forBundleId bundleId: String?) -> String? {
        guard let bundleId, let entry = entries[bundleId] else { return nil }
        // Require at least 2 samples so one-off off-language dictations don't
        // flip the preference permanently.
        guard entry.sampleCount >= 2 else { return nil }
        return entry.code
    }

    /// Convenience: language for the currently-frontmost app.
    func languageForFrontmostApp() -> String? {
        language(forBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    // MARK: - Recording

    /// Detect the language of `text` and update the preference for `bundleId`.
    /// Called from AppState after each successful dictation.
    func record(text: String, bundleId: String?) {
        guard let bundleId else { return }
        guard text.split(separator: " ").count >= 3 else { return } // too short to detect

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)

        guard let lang = recognizer.dominantLanguage else { return }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        let confidence = hypotheses[lang] ?? 0
        guard confidence >= minConfidence else { return }

        let code = lang.rawValue // e.g. "en", "de", "fr"

        if var existing = entries[bundleId] {
            if existing.code == code {
                existing.sampleCount = min(existing.sampleCount + 1, maxSampleCount)
            } else {
                // User switched language in this app. Decay the old pref; if
                // it drops to zero, adopt the new code.
                existing.sampleCount -= 1
                if existing.sampleCount <= 0 {
                    existing.code = code
                    existing.sampleCount = 1
                }
            }
            existing.lastUpdated = Date()
            entries[bundleId] = existing
        } else {
            entries[bundleId] = Entry(code: code, sampleCount: 1, lastUpdated: Date())
        }

        save()
        Log.write("Language learning: \(bundleId) → \(code) (confidence \(String(format: "%.2f", confidence)), samples \(entries[bundleId]?.sampleCount ?? 0))")
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }
}
