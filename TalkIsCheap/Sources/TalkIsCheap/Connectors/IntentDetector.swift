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
        ("shopify",  ["shopify"]),
        ("stripe",   ["stripe"]),
        ("github",   ["github", "git hub", "git-hub"]),
        ("ga4",      ["google analytics", "analytics", "ga4"]),
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
