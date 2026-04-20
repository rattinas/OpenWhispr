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

        let q = intent.rawQuery.lowercased()
        let createMarkers = [
            "erstelle", "erstell ", "ersteller",
            "neuer termin", "neue termin", "neuen termin", "neuer meeting", "neues meeting",
            "termin anlegen", "meeting anlegen", "schedule",
            "create an event", "create event", "create a meeting", "create meeting",
            "add event", "add a meeting", "new event", "new meeting",
            "book ", "plan einen", "trage ein"
        ]
        if createMarkers.contains(where: { q.contains($0) }) {
            return try await createEvent(intent: intent)
        }

        return try await upcomingEvents(intent: intent)
    }

    // MARK: - Create event

    private func createEvent(intent: ConnectorIntent) async throws -> ConnectorResult {
        // Ask Claude Haiku to extract structured event details from the
        // free-form voice query. This covers natural-language date / time
        // parsing ("heute 13 Uhr", "morgen 10 Uhr", "am Montag um 9") that
        // would be painful to regex.
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let tz = TimeZone.current.identifier
        let extractionSystem = """
        You extract Google Calendar event details from a natural-language \
        command. Return ONLY strict JSON in this schema:
        {
          "summary": string,
          "startISO": string (ISO 8601 with timezone, e.g. 2026-04-20T13:00:00+02:00),
          "endISO": string (ISO 8601, default startISO + 60 min if not specified),
          "description": string?,
          "location": string?,
          "attendeesEmails": string[] | null
        }
        Current moment (ISO): \(nowISO). User's timezone: \(tz). If the user \
        says "heute" assume today's date. "Morgen" = tomorrow. "13 Uhr" = \
        13:00 local. "Test" without other meaning is a valid summary.
        """

        let extracted = try await ProxyClient.polish(
            text: intent.rawQuery,
            systemPrompt: extractionSystem,
            model: "claude-haiku-4-5-20251001"
        )

        // Claude might wrap the JSON in markdown code fences — strip them.
        let cleanJSON = extracted
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleanJSON.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ConnectorResult(
                connectorId: id, connectorName: name, icon: icon,
                answer: "⚠️ Ich konnte die Termin-Details nicht parsen. Versuch's nochmal mit: \"Erstelle einen Termin morgen 14 Uhr, Titel: Projekt Review\".\n\nRaw: \(cleanJSON.prefix(400))",
                rawData: ["extracted": cleanJSON],
                timeRange: intent.timeRange, cachedAt: Date()
            )
        }

        guard let summary = parsed["summary"] as? String, !summary.isEmpty,
              let startISO = parsed["startISO"] as? String,
              let endISO = parsed["endISO"] as? String
        else {
            throw ConnectorError.parseError("Missing summary/startISO/endISO in \(cleanJSON.prefix(200))")
        }

        var body: [String: Any] = [
            "summary": summary,
            "start": ["dateTime": startISO, "timeZone": tz],
            "end":   ["dateTime": endISO,   "timeZone": tz],
        ]
        if let desc = parsed["description"] as? String, !desc.isEmpty {
            body["description"] = desc
        }
        if let loc = parsed["location"] as? String, !loc.isEmpty {
            body["location"] = loc
        }
        if let emails = parsed["attendeesEmails"] as? [String], !emails.isEmpty {
            body["attendees"] = emails.map { ["email": $0] }
        }

        let data2 = try await pipedreamProxy(
            url: "https://www.googleapis.com/calendar/v3/calendars/primary/events",
            method: "POST",
            body: body
        )

        guard let eventJson = try? JSONSerialization.jsonObject(with: data2) as? [String: Any]
        else {
            throw ConnectorError.parseError("Create event response unparseable")
        }

        if let err = eventJson["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? "Unknown error"
            throw ConnectorError.apiError("Google Calendar: \(msg)")
        }

        // Nice confirmation in the user's implied language — pick German
        // if the query sounded German, else English.
        let isGerman = looksGerman(intent.rawQuery)
        let eventId = eventJson["id"] as? String ?? ""
        let htmlLink = eventJson["htmlLink"] as? String ?? ""

        let display = ISO8601DateFormatter()
        display.formatOptions = [.withInternetDateTime]
        let start = display.date(from: startISO)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: isGerman ? "de_DE" : "en_US")
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        let prettyStart = start.map(fmt.string(from:)) ?? startISO

        var md = "## ✅ \(isGerman ? "Termin erstellt" : "Event created")\n\n"
        md += "**\(summary)**\n"
        md += "🕐 \(prettyStart)\n"
        if let loc = parsed["location"] as? String, !loc.isEmpty { md += "📍 \(loc)\n" }
        if let desc = parsed["description"] as? String, !desc.isEmpty {
            md += "\n\(desc)\n"
        }
        if !htmlLink.isEmpty {
            md += "\n[\(isGerman ? "Im Kalender öffnen" : "Open in Calendar")](\(htmlLink))"
        }

        return ConnectorResult(
            connectorId: id, connectorName: name, icon: icon,
            answer: md,
            rawData: [
                "eventId": eventId,
                "htmlLink": htmlLink,
                "summary": summary,
                "startISO": startISO,
                "endISO": endISO,
            ],
            timeRange: intent.timeRange,
            cachedAt: Date()
        )
    }

    private func looksGerman(_ s: String) -> Bool {
        let q = s.lowercased()
        let markers = ["erstell", "termin", "heute", "morgen", "ich", "einen", "meine", "neuen"]
        return markers.contains { q.contains($0) }
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

        let heading = range.displayName.prefix(1).uppercased() + range.displayName.dropFirst()

        // Parse all events up front so we can group and format nicely.
        struct ParsedEvent {
            let title: String
            let start: Date?
            let end: Date?
            let isAllDay: Bool
            let location: String?
            let isOnline: Bool
            let attendeeCount: Int
        }

        let parsed: [ParsedEvent] = items.compactMap { raw in
            let title = (raw["summary"] as? String)?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "Untitled"
            let startObj = raw["start"] as? [String: Any] ?? [:]
            let endObj = raw["end"] as? [String: Any] ?? [:]
            let startDt: Date? = (startObj["dateTime"] as? String).flatMap(isoFormatter.date)
            let endDt: Date? = (endObj["dateTime"] as? String).flatMap(isoFormatter.date)
            let isAllDay = startObj["date"] != nil && startObj["dateTime"] == nil
            let loc = (raw["location"] as? String)?.trimmingCharacters(in: .whitespaces)
            let hangoutLink = (raw["hangoutLink"] as? String) ?? ""
            let conferenceData = raw["conferenceData"] != nil
            let isOnline = !hangoutLink.isEmpty || conferenceData ||
                (loc?.lowercased().contains("zoom") == true) ||
                (loc?.lowercased().contains("meet.google") == true) ||
                (loc?.lowercased().contains("teams.microsoft") == true)
            let attendees = (raw["attendees"] as? [[String: Any]])?.count ?? 0
            return ParsedEvent(
                title: title,
                start: startDt,
                end: endDt,
                isAllDay: isAllDay,
                location: (loc?.isEmpty ?? true) ? nil : loc,
                isOnline: isOnline,
                attendeeCount: attendees
            )
        }

        if parsed.isEmpty {
            return ConnectorResult(
                connectorId: id, connectorName: name, icon: icon,
                answer: "## 📅 Calendar — \(heading)\n\n_Nothing scheduled._",
                rawData: json, timeRange: range, cachedAt: Date()
            )
        }

        let timeOnly = DateFormatter()
        timeOnly.dateFormat = "HH:mm"
        let timeWithDay = DateFormatter()
        timeWithDay.dateFormat = "EEE HH:mm"  // Mon 14:30
        timeWithDay.locale = Locale.autoupdatingCurrent
        let dateShort = DateFormatter()
        dateShort.dateFormat = "EEE d MMM"    // Mon 21 Apr
        dateShort.locale = Locale.autoupdatingCurrent

        let cal = Calendar.current
        let todayRange = cal.startOfDay(for: now)...cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!

        // Is everything in today? Then we only need HH:mm. Otherwise day prefix.
        let allToday = parsed.allSatisfy { ($0.start.map { todayRange.contains($0) } ?? false) }

        // Identify which event is "next up" so we can highlight it.
        let nextIndex = parsed.firstIndex(where: { ($0.start ?? .distantPast) >= now })

        // Build rows.
        var rows: [String] = []
        for (i, e) in parsed.enumerated() {
            let timeLabel: String
            if let start = e.start {
                let startStr = allToday ? timeOnly.string(from: start) : timeWithDay.string(from: start)
                let endStr = e.end.map(timeOnly.string(from:))
                timeLabel = endStr.map { "\(startStr)–\($0)" } ?? startStr
            } else if e.isAllDay {
                timeLabel = "all-day"
            } else {
                timeLabel = "—"
            }

            var pieces: [String] = []
            if e.isOnline { pieces.append("📹") }
            if e.attendeeCount > 0 { pieces.append("👥 \(e.attendeeCount)") }
            if let loc = e.location, !e.isOnline { pieces.append("📍 \(loc)") }
            let meta = pieces.isEmpty ? "" : "  \(pieces.joined(separator: " · "))"

            let prefix = (i == nextIndex) ? "▶︎ **NEXT** " : "• "
            rows.append("\(prefix)`\(timeLabel)` **\(e.title)**\(meta)")
        }

        // Summarise day at the top.
        let todayLabel: String = {
            if allToday {
                let df = DateFormatter(); df.dateStyle = .full
                return df.string(from: now)
            }
            return heading
        }()

        var md = "## 📅 \(todayLabel)\n\n"
        md += "**\(parsed.count) event\(parsed.count == 1 ? "" : "s")**"
        if let nxt = nextIndex, let start = parsed[nxt].start {
            let mins = Int(start.timeIntervalSince(now) / 60)
            if mins > 0 {
                if mins < 60 {
                    md += " · next in \(mins) min"
                } else {
                    md += " · next at \(timeOnly.string(from: start))"
                }
            } else {
                md += " · happening now"
            }
        }
        md += "\n\n"
        md += rows.joined(separator: "\n")

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

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
