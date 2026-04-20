import Foundation

/// Detects which connector to use and parses time references from a voice query.
/// Supports German and English.
struct IntentDetector {

    // MARK: - Public

    static func detect(from query: String) -> ConnectorIntent {
        let normalized = query
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)

        let connectorHint = extractConnectorHint(from: normalized)
        let timeRange = extractTimeRange(from: normalized)

        return ConnectorIntent(
            rawQuery: query,
            connectorHint: connectorHint,
            timeRange: timeRange,
            normalized: normalized
        )
    }

    // MARK: - Service name detection

    private static let servicePatterns: [(id: String, patterns: [String])] = [
        // Order matters: longer/more specific first. "google ads" must win
        // over "google analytics" if the user mentions both.
        ("google_ads",     ["google ads", "googleads", "adwords"]),
        ("meta_ads",       ["meta ads", "facebook ads", "instagram ads", "fb ads"]),
        ("ga4",            ["google analytics", "analytics", "ga4"]),
        ("google_calendar", ["google calendar", "calendar", "kalender", "termin", "meeting", "schedule"]),
        ("gmail",          ["gmail", "google mail", "email", "mail", "posteingang", "letzte mail", "last email"]),
        ("shopify",        ["shopify"]),
        ("stripe",         ["stripe"]),
        ("github",         ["github", "git hub", "git-hub"]),
        // Generic brand mentions — run after the multi-word variants
        // so "facebook werbeausgaben" still picks meta_ads.
        ("meta_ads",       ["facebook", "instagram", "meta"]),
    ]

    private static func extractConnectorHint(from normalized: String) -> String? {
        for (id, patterns) in servicePatterns {
            if patterns.contains(where: { normalized.contains($0) }) {
                return id
            }
        }
        return nil
    }

    // MARK: - Time range detection (German + English)

    private static func extractTimeRange(from normalized: String) -> TimeRange {
        // Order matters: longer/more specific matches first

        // Day after tomorrow — "übermorgen" (folds to "ubermorgen"), "day after tomorrow"
        if containsAny(normalized, [
            "ubermorgen", "day after tomorrow"
        ]) {
            let cal = Calendar.current
            let start = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: Date()))!
            let end   = cal.date(byAdding: .day, value: 3, to: cal.startOfDay(for: Date()))!
            return .custom(from: start, to: end)
        }

        // Next week — "nächste woche" (folds to "nachste woche"), "next week"
        if containsAny(normalized, [
            "nachste woche", "naechste woche", "kommende woche",
            "next week", "upcoming week"
        ]) {
            let cal = Calendar.current
            let now = Date()
            var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            comps.weekday = cal.firstWeekday
            let thisWeekStart = cal.date(from: comps) ?? now
            let nextWeekStart = cal.date(byAdding: .weekOfYear, value: 1, to: thisWeekStart)!
            let nextWeekEnd   = cal.date(byAdding: .day, value: 7, to: nextWeekStart)!
            return .custom(from: nextWeekStart, to: nextWeekEnd)
        }

        // Last month — "letzten/letztem/letzter monat", "last month", "vergangenen monat"
        if containsAny(normalized, [
            "letzten monat", "letztem monat", "letzter monat",
            "vergangenen monat", "vergangener monat",
            "last month", "previous month"
        ]) { return .lastMonth }

        // This month — "diesen/diesem monat", "this month"
        if containsAny(normalized, [
            "diesen monat", "diesem monat", "dieses monats",
            "aktuellen monat", "aktueller monat",
            "this month", "current month"
        ]) { return .thisMonth }

        // Last week — "letzte/letzter woche", "last week"
        if containsAny(normalized, [
            "letzte woche", "letzter woche", "letzten woche",
            "vergangene woche", "vergangener woche",
            "last week", "previous week"
        ]) { return .lastWeek }

        // This week — "diese woche", "this week"
        if containsAny(normalized, [
            "diese woche", "dieser woche", "dieses woche",
            "aktuelle woche", "aktueller woche",
            "this week", "current week"
        ]) { return .thisWeek }

        // Tomorrow — "morgen" / "tomorrow" (must come after "übermorgen" check above,
        // otherwise "übermorgen" would match the "morgen" substring).
        if containsAny(normalized, ["morgen", "tomorrow"]) {
            return .tomorrow
        }

        // Yesterday — "gestern", "yesterday"
        if containsAny(normalized, ["gestern", "yesterday"]) { return .yesterday }

        // Today / now — explicit or implicit default
        // (also catches "heute", "today", "jetzt", "now")
        return .today
    }

    private static func containsAny(_ string: String, _ patterns: [String]) -> Bool {
        patterns.contains { string.contains($0) }
    }
}
