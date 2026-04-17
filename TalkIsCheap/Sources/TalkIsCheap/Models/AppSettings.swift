import Foundation
import SwiftUI

/// Central settings store, persisted to UserDefaults with @AppStorage
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // API Keys
    @AppStorage("groqApiKey") var groqApiKey: String = ""
    @AppStorage("anthropicApiKey") var anthropicApiKey: String = ""
    @AppStorage("deepgramApiKey") var deepgramApiKey: String = ""

    // Providers
    @AppStorage("sttProvider") var sttProvider: String = "groq"
    @AppStorage("polishProvider") var polishProvider: String = "anthropic"
    @AppStorage("braveApiKey") var braveApiKey: String = ""

    // Language
    @AppStorage("language") var language: String = "de"

    // Hotkey
    @AppStorage("hotkeyCode") var hotkeyCode: Int = 0x3B // F-key default, 0 = ctrl

    // Microphone
    @AppStorage("selectedMicDevice") var selectedMicDevice: String = "" // empty = default

    // Search
    @AppStorage("searchDepth") var searchDepth: String = "balanced" // minimal, balanced, detailed
    @AppStorage("searchModel") var searchModel: String = "claude-sonnet-4-6" // claude-opus-4-6, claude-sonnet-4-6

    // Cassette overlay
    @AppStorage("cassetteOpacity") var cassetteOpacity: Double = 0.7

    // Audio dimming
    @AppStorage("dimAudioWhileRecording") var dimAudioWhileRecording: Bool = true

    // License & Activation
    @AppStorage("licenseKey") var licenseKey: String = ""
    @AppStorage("activationToken") var activationToken: String = ""
    @AppStorage("activatedAt") var activatedAt: String = ""
    @AppStorage("lastValidationCheck") var lastValidationCheck: Double = 0
    @AppStorage("trialUses") var trialUses: Int = 0

    // Subscription & Proxy Mode
    @AppStorage("tier") var tier: String = ""  // "trial", "lifetime", "pro_monthly", "pro_annual"
    @AppStorage("useCloudProxy") var useCloudProxy: Bool = false
    @AppStorage("trialUsesRemaining") var trialUsesRemaining: Int = 10
    @AppStorage("subscriptionStatus") var subscriptionStatus: String = ""
    @AppStorage("currentPeriodEnd") var currentPeriodEnd: String = ""

    // Custom Dictionary (for proper nouns, company names, technical terms)
    @AppStorage("customDictionary") var customDictionary: String = ""

    // Onboarding
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    @AppStorage("paywallDismissed") var paywallDismissed: Bool = false

    // Polish mode
    @AppStorage("activePolishMode") var activePolishMode: String = "clean"
    @AppStorage("appAwareContext") var appAwareContext: Bool = true

    static let languages: [(code: String, name: String)] = [
        ("auto", "Auto-Detect"),
        ("de", "Deutsch"),
        ("en", "English"),
        ("fr", "Français"),
        ("es", "Español"),
        ("it", "Italiano"),
        ("pt", "Português"),
        ("nl", "Nederlands"),
        ("ja", "日本語"),
        ("zh", "中文"),
    ]

    static let currentVersion = "2.0.0"
    static let trialLimit = 50

    var isTrialExpired: Bool { trialUses >= Self.trialLimit }
    var remainingTrial: Int { max(0, Self.trialLimit - trialUses) }

    /// Whether this install should use the cloud proxy (Trial + Pro tiers).
    var shouldUseProxy: Bool {
        useCloudProxy && (tier == "trial" || tier == "pro_monthly" || tier == "pro_annual")
    }

    /// Should user see the paywall? Trial exhausted + no other mode configured.
    var shouldShowPaywall: Bool {
        tier == "trial" && trialUsesRemaining <= 0 && !paywallDismissed
    }

    /// Tier display label for UI
    var tierLabel: String {
        switch tier {
        case "trial": return "Free Trial"
        case "lifetime": return "Lifetime"
        case "pro_monthly": return "Pro Monthly"
        case "pro_annual": return "Pro Annual"
        case "canceled": return "Canceled"
        default: return "Not activated"
        }
    }

    /// Human-readable name for the current hotkey
    var hotkeyName: String {
        switch hotkeyCode {
        case 0, 59, 62: return "Control"
        case 0x60: return "F5"
        case 0x61: return "F6"
        case 0x64: return "F8"
        case 0x65: return "F9"
        case 0x3B: return "Control"
        default: return "Key"
        }
    }

    /// Short name for UI labels
    var hotkeyShort: String {
        switch hotkeyCode {
        case 0, 59, 62, 0x3B: return "Ctrl"
        case 0x60: return "F5"
        case 0x61: return "F6"
        case 0x64: return "F8"
        case 0x65: return "F9"
        default: return "Key"
        }
    }
}
