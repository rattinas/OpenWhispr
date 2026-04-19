import Foundation

// MARK: - Time Range

enum TimeRange: Equatable {
    case today
    case yesterday
    case thisWeek
    case lastWeek
    case thisMonth
    case lastMonth
    case custom(from: Date, to: Date)

    var startDate: Date {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .today:
            return cal.startOfDay(for: now)
        case .yesterday:
            return cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: now)!)
        case .thisWeek:
            var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            comps.weekday = cal.firstWeekday
            return cal.date(from: comps) ?? now
        case .lastWeek:
            var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            comps.weekday = cal.firstWeekday
            let thisWeekStart = cal.date(from: comps) ?? now
            return cal.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart)!
        case .thisMonth:
            return cal.date(from: cal.dateComponents([.year, .month], from: now))!
        case .lastMonth:
            let thisMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            return cal.date(byAdding: .month, value: -1, to: thisMonthStart)!
        case .custom(let from, _):
            return from
        }
    }

    var endDate: Date {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .today:
            return now
        case .yesterday:
            return cal.startOfDay(for: now)
        case .thisWeek:
            return now
        case .lastWeek:
            var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            comps.weekday = cal.firstWeekday
            return cal.date(from: comps) ?? now
        case .thisMonth:
            return now
        case .lastMonth:
            return cal.date(from: cal.dateComponents([.year, .month], from: now))!
        case .custom(_, let to):
            return to
        }
    }

    var displayName: String {
        switch self {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .thisWeek: return "this week"
        case .lastWeek: return "last week"
        case .thisMonth: return "this month"
        case .lastMonth: return "last month"
        case .custom(let from, let to):
            let df = DateFormatter()
            df.dateStyle = .short
            return "\(df.string(from: from)) – \(df.string(from: to))"
        }
    }
}

// MARK: - Connector Intent

struct ConnectorIntent {
    let rawQuery: String
    let connectorHint: String?   // explicitly named service, lowercased
    let timeRange: TimeRange
    let normalized: String       // lowercased, diacritic-insensitive
}

// MARK: - Connector Result

struct ConnectorResult {
    let connectorId: String
    let connectorName: String
    let icon: String
    let answer: String           // formatted Markdown
    let rawData: [String: Any]
    let timeRange: TimeRange
    let cachedAt: Date
}

// MARK: - Connector Protocol

protocol Connector: AnyObject {
    var id: String { get }
    var name: String { get }
    var icon: String { get }
    var accentColorHex: String { get }
    var keywords: [String] { get }        // trigger words (lowercase)
    var serviceNames: [String] { get }    // how users say this service (lowercase)

    var isConnected: Bool { get }

    // Credential fields this connector needs, in display order: key → label
    var credentialFields: [(key: String, label: String, isSecret: Bool)] { get }

    func connect(credentials: [String: String]) throws
    func disconnect()
    func query(intent: ConnectorIntent) async throws -> ConnectorResult

    /// Make a cheap live API call to verify the credentials really work.
    /// Called right after connect() during the setup flow so we surface a
    /// bad token immediately instead of on the user's first voice query.
    /// Throws `ConnectorError` on failure.
    func testConnection() async throws
}

extension Connector {
    // Default test: a `.today` query. Connectors that would be expensive or
    // data-destructive for this should override with something cheaper.
    func testConnection() async throws {
        let intent = ConnectorIntent(
            rawQuery: "test",
            connectorHint: id,
            timeRange: .today,
            normalized: "test"
        )
        _ = try await query(intent: intent)
    }
}

// MARK: - Connector Error

enum ConnectorError: LocalizedError {
    case notConnected(String)
    case apiError(String)
    case parseError(String)
    case missingCredential(String)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .notConnected(let name):
            return "\(name) is not connected. Add it in Settings → Connected Services."
        case .apiError(let msg): return msg
        case .parseError(let msg): return "Could not parse response: \(msg)"
        case .missingCredential(let field): return "Missing field: \(field)"
        case .rateLimited: return "Rate limited — try again in a moment."
        }
    }
}
