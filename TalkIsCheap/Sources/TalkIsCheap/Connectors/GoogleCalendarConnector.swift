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
        "was steht an", "what's on",
        // Free-slot / availability triggers
        "slot", "slots", "freie zeit", "freier slot", "freien slot",
        "wann habe ich zeit", "wann hab ich zeit", "wann bin ich frei",
        "wann passt", "availability", "verfuegbar", "verfügbar",
        "free time", "am i free", "when am i free", "find a time",
        "freien termin", "free slot",
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

        // "Free slot" intent must win over "create" — the user says things like
        // "find me a free slot tomorrow and schedule it" and we want to first
        // show gaps, then let them confirm.
        let freeSlotMarkers = [
            "freie zeit", "freier slot", "freien slot", "freies zeitfenster",
            "freien termin", "freier termin",
            "wann habe ich zeit", "wann hab ich zeit", "wann bin ich frei",
            "wann passt", "wann ist zeit", "wann bin ich verfuegbar",
            "wann bin ich verfügbar", "verfuegbarkeit", "verfügbarkeit",
            "free slot", "free slots", "free time", "am i free",
            "when am i free", "find a time", "find me a time",
            "find a slot", "find me a slot", "availability", "any openings",
        ]
        if freeSlotMarkers.contains(where: { q.contains($0) }) {
            return try await findFreeSlot(intent: intent)
        }

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

        let isGerman = looksGerman(intent.rawQuery)
        let display = ISO8601DateFormatter()
        display.formatOptions = [.withInternetDateTime]
        let start = display.date(from: startISO)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: isGerman ? "de_DE" : "en_US")
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        let prettyStart = start.map(fmt.string(from:)) ?? startISO

        var md = "## 📅 \(isGerman ? "Termin bereit zum Anlegen" : "Event ready to create")\n\n"
        md += "🕐 \(prettyStart)\n\n"
        md += "*\(isGerman ? "Passe die Felder an, dann Termin anlegen klicken." : "Adjust the fields below, then click Create event.")*"

        var fields: [EditableField] = [
            EditableField(key: "summary", label: isGerman ? "Titel" : "Title", multiline: false, value: summary),
            EditableField(key: "location", label: isGerman ? "Ort" : "Location", multiline: false,
                          value: (parsed["location"] as? String) ?? ""),
            EditableField(key: "description", label: isGerman ? "Beschreibung" : "Description", multiline: true,
                          value: (parsed["description"] as? String) ?? ""),
        ]
        // Show a read-only-ish "Attendees" field for quick edit too.
        if let emails = parsed["attendeesEmails"] as? [String], !emails.isEmpty {
            fields.append(EditableField(
                key: "attendeesCsv",
                label: isGerman ? "Teilnehmer (Komma-getrennt)" : "Attendees (comma-separated)",
                multiline: false, value: emails.joined(separator: ", ")
            ))
        }

        let hidden: [String: String] = [
            "startISO": startISO,
            "endISO": endISO,
            "timezone": tz,
        ]

        let pending = PendingAction(
            kind: "calendar.create",
            title: isGerman ? "Termin anlegen" : "Create event",
            appSlug: "google_calendar",
            endpoint: "https://www.googleapis.com/calendar/v3/calendars/primary/events",
            method: "POST",
            editable: fields,
            hidden: hidden
        )

        return ConnectorResult(
            connectorId: id, connectorName: name, icon: icon,
            answer: md,
            rawData: [
                "summary": summary,
                "startISO": startISO,
                "endISO": endISO,
            ],
            timeRange: intent.timeRange,
            cachedAt: Date(),
            pendingActions: [pending]
        )
    }

    // MARK: - Find free slot

    private func findFreeSlot(intent: ConnectorIntent) async throws -> ConnectorResult {
        let now = Date()
        let cal = Calendar.current
        let tz = TimeZone.current
        let isGerman = looksGerman(intent.rawQuery)

        // 1. Use Claude Haiku to extract day + duration + time window from the raw query.
        let nowISO = ISO8601DateFormatter().string(from: now)
        let system = """
        You extract a free-slot search specification from a natural-language \
        calendar query. Return ONLY strict JSON, no prose, no markdown fences:
        {
          "dateISO": string (YYYY-MM-DD for the day to search),
          "durationMinutes": number (default 30 if unspecified),
          "earliestTime": string (HH:MM 24h, default "09:00"),
          "latestTime": string (HH:MM 24h, default "18:00")
        }
        Current moment: \(nowISO). User's timezone: \(tz.identifier).
        "heute"/"today" = today. "morgen"/"tomorrow" = tomorrow. \
        "übermorgen"/"day after tomorrow" = +2 days. \
        "nächste Woche"/"next week" = next Monday. \
        If a duration like "30 min", "eine Stunde", "1h", "zwei Stunden" is present, \
        use that. Minimum 15, cap at 480.
        """
        let extracted = (try? await ProxyClient.polish(
            text: intent.rawQuery,
            systemPrompt: system,
            model: "claude-haiku-4-5-20251001"
        )) ?? ""
        let cleanJSON = extracted
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = (cleanJSON.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
            as? [String: Any]) ?? [:]

        // 2. Resolve the target day. Prefer Claude's dateISO; fall back to intent.timeRange.
        let dayDf = DateFormatter()
        dayDf.dateFormat = "yyyy-MM-dd"
        dayDf.timeZone = tz
        dayDf.locale = Locale(identifier: "en_US_POSIX")
        let fallbackDay: Date = {
            switch intent.timeRange {
            case .tomorrow:
                return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            case .yesterday:
                return cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
            case .custom(let from, _):
                return cal.startOfDay(for: from)
            default:
                return cal.startOfDay(for: now)
            }
        }()
        let dayStart: Date = {
            if let s = parsed["dateISO"] as? String, let d = dayDf.date(from: s) {
                return cal.startOfDay(for: d)
            }
            return fallbackDay
        }()
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!

        // 3. Duration + working window.
        let rawDuration = (parsed["durationMinutes"] as? Int)
            ?? Int((parsed["durationMinutes"] as? Double) ?? 30)
        let duration = max(15, min(480, rawDuration))

        func parseHM(_ s: String?, fallback: (h: Int, m: Int)) -> (h: Int, m: Int) {
            guard let s = s else { return fallback }
            let parts = s.split(separator: ":")
            guard parts.count == 2,
                  let h = Int(parts[0]), let m = Int(parts[1]),
                  (0..<24).contains(h), (0..<60).contains(m) else { return fallback }
            return (h, m)
        }
        let early = parseHM(parsed["earliestTime"] as? String, fallback: (9, 0))
        let late  = parseHM(parsed["latestTime"]   as? String, fallback: (18, 0))

        guard let windowStart = cal.date(bySettingHour: early.h, minute: early.m, second: 0, of: dayStart),
              let windowEnd   = cal.date(bySettingHour: late.h,  minute: late.m,  second: 0, of: dayStart),
              windowEnd > windowStart
        else {
            throw ConnectorError.parseError("Invalid time window for free-slot search.")
        }

        // If the target day is today, don't propose slots in the past — round `now` up to next 15 min.
        var effectiveStart = windowStart
        if cal.isDate(dayStart, inSameDayAs: now) {
            let minute = cal.component(.minute, from: now)
            let hour = cal.component(.hour, from: now)
            let bumpedMinute = ((minute / 15) + 1) * 15
            let rounded: Date = {
                if bumpedMinute >= 60 {
                    let h = hour + 1
                    return cal.date(bySettingHour: h, minute: 0, second: 0, of: now) ?? now
                } else {
                    return cal.date(bySettingHour: hour, minute: bumpedMinute, second: 0, of: now) ?? now
                }
            }()
            effectiveStart = max(windowStart, rounded)
        }

        let timeOnly = DateFormatter()
        timeOnly.dateFormat = "HH:mm"
        let dayLabel = DateFormatter()
        dayLabel.dateStyle = .full
        dayLabel.locale = Locale(identifier: isGerman ? "de_DE" : "en_US")

        if effectiveStart >= windowEnd {
            var md = "## 📅 \(isGerman ? "Freie Slots" : "Free slots") — \(dayLabel.string(from: dayStart))\n\n"
            md += isGerman
                ? "_Keine freien Fenster mehr in diesem Zeitraum._"
                : "_No remaining free windows in that range._"
            return ConnectorResult(
                connectorId: id, connectorName: name, icon: icon,
                answer: md, rawData: [:], timeRange: intent.timeRange, cachedAt: Date()
            )
        }

        // 4. Fetch events for the target day and build busy intervals.
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let timeMin = isoFormatter.string(from: dayStart)
        let timeMax = isoFormatter.string(from: dayEnd)
        let url = "https://www.googleapis.com/calendar/v3/calendars/primary/events"
            + "?singleEvents=true&orderBy=startTime&maxResults=50"
            + "&timeMin=\(timeMin.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)"
            + "&timeMax=\(timeMax.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)"

        let data = try await pipedreamProxy(url: url)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let items = (json["items"] as? [[String: Any]]) ?? []

        var busy: [(start: Date, end: Date)] = []
        let allDayDf = DateFormatter()
        allDayDf.dateFormat = "yyyy-MM-dd"
        allDayDf.timeZone = tz
        allDayDf.locale = Locale(identifier: "en_US_POSIX")
        for raw in items {
            // Skip declined-by-me events — they don't actually block the calendar.
            if let attendees = raw["attendees"] as? [[String: Any]] {
                if attendees.contains(where: {
                    ($0["self"] as? Bool) == true &&
                    ($0["responseStatus"] as? String) == "declined"
                }) { continue }
            }
            // Transparent events (marked "free") don't block either.
            if let transparency = raw["transparency"] as? String,
               transparency == "transparent" {
                continue
            }
            guard let startObj = raw["start"] as? [String: Any],
                  let endObj   = raw["end"]   as? [String: Any] else { continue }
            if let sStr = startObj["dateTime"] as? String,
               let eStr = endObj["dateTime"] as? String,
               let s = isoFormatter.date(from: sStr),
               let e = isoFormatter.date(from: eStr) {
                busy.append((s, e))
            } else if let sStr = startObj["date"] as? String,
                      let eStr = endObj["date"] as? String,
                      let s = allDayDf.date(from: sStr),
                      let e = allDayDf.date(from: eStr) {
                busy.append((s, e))
            }
        }
        busy.sort { $0.start < $1.start }

        // Merge overlapping / adjacent busy intervals.
        var merged: [(start: Date, end: Date)] = []
        for b in busy {
            if var last = merged.last, b.start <= last.end {
                last.end = max(last.end, b.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(b)
            }
        }

        // Compute free gaps within [effectiveStart, windowEnd] of length ≥ duration.
        var free: [(start: Date, end: Date)] = []
        var cursor = effectiveStart
        for b in merged {
            if b.end <= cursor { continue }
            if b.start >= windowEnd { break }
            if b.start > cursor {
                let gapEnd = min(b.start, windowEnd)
                if gapEnd.timeIntervalSince(cursor) >= Double(duration * 60) {
                    free.append((cursor, gapEnd))
                }
            }
            if b.end > cursor { cursor = b.end }
        }
        if cursor < windowEnd, windowEnd.timeIntervalSince(cursor) >= Double(duration * 60) {
            free.append((cursor, windowEnd))
        }

        // 5. Format.
        var md = "## 📅 \(isGerman ? "Freie Slots" : "Free slots") — \(dayLabel.string(from: dayStart))\n\n"
        md += "*\(isGerman ? "Mindestens" : "At least") \(duration) min · "
        md += "\(timeOnly.string(from: windowStart))–\(timeOnly.string(from: windowEnd))*\n\n"

        if free.isEmpty {
            md += isGerman
                ? "_Nichts frei in diesem Fenster. Alles verplant._"
                : "_No free windows in that range. Fully booked._"
            return ConnectorResult(
                connectorId: id, connectorName: name, icon: icon,
                answer: md, rawData: json, timeRange: intent.timeRange, cachedAt: Date()
            )
        }

        for slot in free {
            let mins = Int(slot.end.timeIntervalSince(slot.start) / 60)
            let durLabel: String
            if mins >= 60 {
                let h = mins / 60
                let m = mins % 60
                durLabel = m == 0 ? "\(h)h" : "\(h)h \(m)min"
            } else {
                durLabel = "\(mins) min"
            }
            md += "• `\(timeOnly.string(from: slot.start))–\(timeOnly.string(from: slot.end))` · \(durLabel)\n"
        }
        md += "\n_"
        md += isGerman
            ? "Sag z. B. „Erstelle einen Termin \(dayDf.string(from: dayStart)) 14 Uhr\" um einzubuchen."
            : "Say e.g. \"Create an event on \(dayDf.string(from: dayStart)) at 2pm\" to book."
        md += "_"

        return ConnectorResult(
            connectorId: id, connectorName: name, icon: icon,
            answer: md, rawData: json, timeRange: intent.timeRange, cachedAt: Date()
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
        let cal = Calendar.current
        let startDate: Date
        let endDate: Date
        switch range {
        case .today, .yesterday:
            startDate = now
            endDate = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        case .tomorrow:
            // Span tomorrow's full day.
            startDate = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            endDate = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now))!
        case .thisWeek, .lastWeek:
            startDate = now
            endDate = cal.date(byAdding: .day, value: 7, to: now)!
        case .thisMonth, .lastMonth:
            startDate = now
            endDate = cal.date(byAdding: .month, value: 1, to: now)!
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
            let df = DateFormatter(); df.dateStyle = .full
            if allToday {
                return df.string(from: now)
            }
            if case .tomorrow = range {
                let tomorrow = Calendar.current.date(
                    byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)
                )!
                return "Tomorrow — \(df.string(from: tomorrow))"
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
