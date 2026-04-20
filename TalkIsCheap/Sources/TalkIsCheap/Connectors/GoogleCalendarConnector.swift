import Foundation

/// Google Calendar — upcoming events via Calendar API v3.
/// Auth: Pipedream-managed OAuth. Scope: calendar.readonly.
@MainActor
final class GoogleCalendarConnector: Connector {
    static let shared = GoogleCalendarConnector()
    private init() {}

    let id = "google_calendar"
    let name = "Google Calendar"
    let icon = "calendar"
    let accentColorHex = "#4285F4"

    let keywords: [String] = [
        "calendar", "kalender", "termin", "termine", "meeting",
        "meetings", "event", "events", "appointment", "appointments",
        "nächster termin", "next meeting", "heute", "today", "morgen",
        "tomorrow", "diese woche", "this week", "schedule",
        "was steht an", "what's on"
    ]
    let serviceNames: [String] = ["google calendar", "calendar", "kalender"]
    let category: ConnectorCategory = .productivity
    let pipedreamAppSlug: String? = "google_calendar"

    let setupGuide: [SetupStep] = [
        SetupStep(
            "Sign in to Google",
            detail: "Grants read-only access to your calendar events."
        ),
    ]
    let credentialFields: [(key: String, label: String, isSecret: Bool)] = []

    var isConnected: Bool { isPipedreamConnected }
    func connect(credentials: [String: String]) throws {}
    func disconnect() {}

    // MARK: - Query

    func query(intent: ConnectorIntent) async throws -> ConnectorResult {
        guard isConnected else { throw ConnectorError.notConnected(name) }
        return try await upcomingEvents(intent: intent)
    }

    private func upcomingEvents(intent: ConnectorIntent) async throws -> ConnectorResult {
        // Pick a sensible window. Today by default; expand to "this week"
        // if the user explicitly asked for week scope.
        let now = Date()
        let range = intent.timeRange
        let startDate: Date
        let endDate: Date
        switch range {
        case .today, .yesterday:
            startDate = now
            endDate = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        case .thisWeek, .lastWeek:
            startDate = now
            endDate = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        case .thisMonth, .lastMonth:
            startDate = now
            endDate = Calendar.current.date(byAdding: .month, value: 1, to: now)!
        case .custom(let from, let to):
            startDate = from
            endDate = to
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let timeMin = isoFormatter.string(from: startDate)
        let timeMax = isoFormatter.string(from: endDate)

        let url = "https://www.googleapis.com/calendar/v3/calendars/primary/events"
            + "?singleEvents=true&orderBy=startTime&maxResults=15"
            + "&timeMin=\(timeMin.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)"
            + "&timeMax=\(timeMax.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)"

        let data = try await pipedreamProxy(url: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]]
        else {
            throw ConnectorError.parseError("Unexpected Google Calendar response")
        }

        let displayFormat = DateFormatter()
        displayFormat.dateStyle = .short
        displayFormat.timeStyle = .short
        let dayOnly = DateFormatter()
        dayOnly.dateStyle = .short

        var lines: [String] = []
        for event in items.prefix(10) {
            let summary = event["summary"] as? String ?? "(no title)"
            let start = (event["start"] as? [String: Any])
            let startStr: String
            if let dt = start?["dateTime"] as? String,
               let d = isoFormatter.date(from: dt) {
                startStr = displayFormat.string(from: d)
            } else if let d = start?["date"] as? String {
                startStr = d
            } else {
                startStr = "?"
            }
            var location = ""
            if let l = event["location"] as? String, !l.isEmpty { location = " · \(l)" }
            lines.append("- **\(summary)** — \(startStr)\(location)")
        }

        let heading = range.displayName.prefix(1).uppercased() + range.displayName.dropFirst()
        var md = "## Calendar — \(heading)\n\n"
        if lines.isEmpty {
            md += "_Nothing scheduled in this window._"
        } else {
            md += "**\(items.count) event\(items.count == 1 ? "" : "s")**\n\n"
            md += lines.joined(separator: "\n")
        }

        return ConnectorResult(
            connectorId: id,
            connectorName: name,
            icon: icon,
            answer: md,
            rawData: json,
            timeRange: range,
            cachedAt: Date()
        )
    }
}
