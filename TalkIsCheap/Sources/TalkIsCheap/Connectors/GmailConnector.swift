import Foundation

/// Gmail — read-only queries ("last email from X", "unread count") via
/// the Gmail v1 API (`gmail.googleapis.com/gmail/v1/users/me/…`).
///
/// Auth: Nango-managed OAuth only. Scope: `gmail.readonly`.
@MainActor
final class GmailConnector: Connector {
    static let shared = GmailConnector()
    private init() {}

    // MARK: Identity
    let id = "gmail"
    let name = "Gmail"
    let icon = "envelope.fill"
    let accentColorHex = "#EA4335"

    let keywords: [String] = [
        "gmail", "mail", "email", "e-mail", "mails", "emails",
        "inbox", "posteingang", "nachricht", "nachrichten", "message",
        "unread", "ungelesen", "von", "from", "letzte mail",
        "last email", "latest email"
    ]
    let serviceNames: [String] = ["gmail", "google mail", "email", "mail"]
    let category: ConnectorCategory = .productivity
    let nangoProvider: String? = "google-mail"
    let pipedreamAppSlug: String? = "gmail"

    let setupGuide: [SetupStep] = [
        SetupStep(
            "One-click via Nango",
            detail: "Nango's shared OAuth app handles the Gmail scope for you — just authorise with Google."
        ),
    ]
    let credentialFields: [(key: String, label: String, isSecret: Bool)] = []

    var isConnected: Bool { isPipedreamConnected || isNangoConnected }

    func connect(credentials: [String: String]) throws {
        // Everything runs via Nango — nothing to store locally.
    }

    func disconnect() {}

    // MARK: Query

    func query(intent: ConnectorIntent) async throws -> ConnectorResult {
        guard isConnected else { throw ConnectorError.notConnected(name) }

        let q = intent.rawQuery.lowercased()

        // Triage path: open-ended questions about what needs attention.
        // Picks up "urgent", "dringend", "antworten", "reply", "priority",
        // "important", "muss ich", "wichtig" — runs Claude over a rich
        // inbox snapshot (labels, snippets, read state, thread position)
        // so it can answer questions like "welche mails muss ich dringend
        // beantworten" with actual reasoning.
        let triageMarkers = [
            "dringend", "wichtig", "priority", "urgent", "important",
            "muss ich beantworten", "muss antworten", "need to reply",
            "needs answer", "needs an answer", "pending", "offene",
            "unbeantwortet", "follow up", "follow-up", "action needed",
            "welche mails", "welche e-mails", "which emails", "which mails",
            "what should i", "was soll ich"
        ]
        if triageMarkers.contains(where: { q.contains($0) }) {
            return try await smartTriage(intent: intent)
        }

        // Heuristic: if the query mentions a sender name/email, search for that.
        let sender = extractSender(from: intent.rawQuery)
        if let sender {
            return try await lastMessageFromSender(sender, intent: intent)
        }
        return try await recentInboxSummary(intent: intent)
    }

    // MARK: - Smart triage (Claude Haiku over a rich inbox snapshot)

    private func smartTriage(intent: ConnectorIntent) async throws -> ConnectorResult {
        // Fetch user's labels first so we can flag "needs answer"-style
        // ones that the user has defined themselves.
        let labelData = try await apiGet(path: "/gmail/v1/users/me/labels")
        let labelsJson = try? JSONSerialization.jsonObject(with: labelData) as? [String: Any]
        let rawLabels = (labelsJson?["labels"] as? [[String: Any]]) ?? []
        struct GmailLabel { let id: String; let name: String }
        let labels: [GmailLabel] = rawLabels.compactMap { raw in
            guard let id = raw["id"] as? String, let name = raw["name"] as? String else { return nil }
            return GmailLabel(id: id, name: name)
        }
        // Build quick id → name map + detect actionable labels.
        let labelNameById = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0.name) })
        let actionableHints = ["answer", "reply", "urgent", "action", "todo", "to-do", "to do", "follow", "wait", "antwort", "wichtig", "dringend"]
        let actionableLabelIds: [String] = labels.compactMap { l in
            let n = l.name.lowercased()
            return actionableHints.contains(where: { n.contains($0) }) ? l.id : nil
        }

        // Pull a healthy-sized chunk of recent messages: union of
        // unread, starred, important, and anything with an actionable
        // user label. Gmail's search operators do the heavy lifting.
        var qParts: [String] = ["is:unread", "is:starred", "is:important"]
        for lid in actionableLabelIds { qParts.append("label:\"\(labelNameById[lid] ?? "")\"") }
        let gmailQuery = qParts.map { "(\($0))" }.joined(separator: " OR ")
        let encodedQ = gmailQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? gmailQuery
        let listData = try await apiGet(path: "/gmail/v1/users/me/messages?maxResults=25&q=\(encodedQ)")

        guard let listJson = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
              let messageStubs = listJson["messages"] as? [[String: Any]], !messageStubs.isEmpty
        else {
            return simpleResult("📭 **Inbox is clear** — no unread, starred, important or action-labelled messages.", intent: intent, raw: [:])
        }

        // Fetch metadata for each message in parallel.
        struct InboxMsg {
            let id: String
            let from: String
            let subject: String
            let snippet: String
            let date: String
            let labelNames: [String]
            let isUnread: Bool
        }
        let ids = messageStubs.prefix(20).compactMap { $0["id"] as? String }
        var messages: [InboxMsg] = []
        try await withThrowingTaskGroup(of: InboxMsg?.self) { group in
            for id in ids {
                group.addTask { [self] in
                    let path = "/gmail/v1/users/me/messages/\(id)?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date"
                    guard let raw = try? await self.apiGet(path: path),
                          let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
                    else { return nil }
                    let headers = ((obj["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
                    func header(_ name: String) -> String {
                        headers.first { ($0["name"] as? String)?.lowercased() == name.lowercased() }?["value"] as? String ?? ""
                    }
                    let labelIds = (obj["labelIds"] as? [String]) ?? []
                    let names = labelIds.compactMap { labelNameById[$0] }
                    return InboxMsg(
                        id: id,
                        from: header("From"),
                        subject: header("Subject").isEmpty ? "(no subject)" : header("Subject"),
                        snippet: (obj["snippet"] as? String) ?? "",
                        date: header("Date"),
                        labelNames: names,
                        isUnread: labelIds.contains("UNREAD")
                    )
                }
            }
            for try await msg in group {
                if let msg { messages.append(msg) }
            }
        }

        // Build Claude context + ask for a triage.
        var ctx = "Here's a snapshot of the user's inbox. Analyse it and answer their question.\n\n"
        ctx += "## Message list (recent unread + starred + important + action-labelled)\n\n"
        for (i, m) in messages.enumerated() {
            ctx += "### [\(i + 1)] \(m.subject)\n"
            ctx += "- **From:** \(cleanFrom(m.from))\n"
            ctx += "- **Date:** \(m.date)\n"
            if !m.labelNames.isEmpty {
                ctx += "- **Labels:** \(m.labelNames.joined(separator: ", "))\n"
            }
            ctx += "- **Unread:** \(m.isUnread ? "yes" : "no")\n"
            if !m.snippet.isEmpty {
                let trimmed = m.snippet.count > 300 ? String(m.snippet.prefix(300)) + "…" : m.snippet
                ctx += "- **Snippet:** \(trimmed)\n"
            }
            ctx += "\n"
        }

        let systemPrompt = """
        You are a voice-first email triage assistant. The user will ask a \
        natural-language question about their inbox (e.g. "welche mails muss \
        ich beantworten?", "was ist wichtig?"). Analyse the provided inbox \
        snapshot and respond in the user's language.

        RULES:
        - Lead with the 3–5 most urgent items, highest priority first.
        - For each, write: a one-line reason (why it matters), who sent it, \
          and what action is expected. Be SHORT. No padding.
        - User labels like "needs answer", "todo", "dringend", "waiting" are \
          strong urgency signals — respect them.
        - Starred / Important flags mean "user marked this", so also strong.
        - Unread + labelled is more urgent than read + labelled.
        - If nothing truly urgent, say so clearly in one sentence.
        - Output valid Markdown. Use bullet points. Bold senders and subjects.
        - Never invent content. Quote snippets when they help.
        """

        let userContent = """
        **Question:** \(intent.rawQuery)

        \(ctx)
        """

        let answer = try await ProxyClient.polish(
            text: userContent,
            systemPrompt: systemPrompt,
            model: "claude-haiku-4-5-20251001"
        )

        return ConnectorResult(
            connectorId: id,
            connectorName: name,
            icon: icon,
            answer: answer,
            rawData: ["messages": messages.count, "labels": labels.count],
            timeRange: intent.timeRange,
            cachedAt: Date()
        )
    }

    /// Unified HTTP GET — picks Pipedream if live, falls back to Nango
    /// (path style), finally Nango-proxy.
    @MainActor
    private func apiGet(path: String) async throws -> Data {
        if isPipedreamConnected {
            return try await pipedreamProxy(url: "https://gmail.googleapis.com\(path)")
        }
        return try await nangoProxy(path: path)
    }

    // MARK: Specific query patterns

    private func lastMessageFromSender(_ sender: String, intent: ConnectorIntent) async throws -> ConnectorResult {
        // Gmail search operators: `from:foo@bar.com` or `from:"Foo Bar"`
        let query = "from:\"\(sender)\""
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let listPath = "/gmail/v1/users/me/messages?maxResults=1&q=\(encoded)"

        let listData = try await apiGet(path: listPath)
        guard let listJson = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
              let messages = listJson["messages"] as? [[String: Any]],
              let first = messages.first,
              let messageId = first["id"] as? String
        else {
            return simpleResult("No message found from **\(sender)**.", intent: intent, raw: [:])
        }

        let msgData = try await apiGet(path: "/gmail/v1/users/me/messages/\(messageId)?format=full")
        guard let msg = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any] else {
            throw ConnectorError.parseError("Couldn't parse Gmail message")
        }

        let snippet = msg["snippet"] as? String ?? ""
        let headers = ((msg["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
        func header(_ name: String) -> String? {
            headers.first { ($0["name"] as? String)?.lowercased() == name.lowercased() }?["value"] as? String
        }
        let subject = header("Subject") ?? "(no subject)"
        let from = header("From") ?? sender
        let date = header("Date") ?? ""

        let body = extractPlainBody(payload: msg["payload"] as? [String: Any] ?? [:])
        let preview = (body.isEmpty ? snippet : body).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = preview.count > 1200 ? String(preview.prefix(1200)) + "…" : preview

        let md = """
        ## Last email from \(sender)

        **Subject:** \(subject)
        **From:** \(from)
        **Date:** \(date)

        \(trimmed)
        """

        return ConnectorResult(
            connectorId: id,
            connectorName: name,
            icon: icon,
            answer: md,
            rawData: msg,
            timeRange: intent.timeRange,
            cachedAt: Date()
        )
    }

    private func recentInboxSummary(intent: ConnectorIntent) async throws -> ConnectorResult {
        // Unread count + 5 most recent subject lines.
        async let unreadData = apiGet(path: "/gmail/v1/users/me/messages?q=is:unread&maxResults=1")
        async let recentData = apiGet(path: "/gmail/v1/users/me/messages?maxResults=5")
        let (unreadRaw, recentRaw) = try await (unreadData, recentData)

        let unreadJson = try? JSONSerialization.jsonObject(with: unreadRaw) as? [String: Any]
        let unreadEstimate = (unreadJson?["resultSizeEstimate"] as? Int) ?? 0

        let recentJson = try? JSONSerialization.jsonObject(with: recentRaw) as? [String: Any]
        let recentIds = (recentJson?["messages"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []

        var summaries: [String] = []
        for id in recentIds.prefix(5) {
            guard let data = try? await apiGet(path: "/gmail/v1/users/me/messages/\(id)?format=metadata&metadataHeaders=From&metadataHeaders=Subject") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let headers = ((obj["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
            let from = headers.first { ($0["name"] as? String)?.lowercased() == "from" }?["value"] as? String ?? "?"
            let subject = headers.first { ($0["name"] as? String)?.lowercased() == "subject" }?["value"] as? String ?? "(no subject)"
            summaries.append("- **\(subject)** — \(cleanFrom(from))")
        }

        var md = "## Gmail inbox\n\n"
        md += "**Unread:** \(unreadEstimate)\n\n"
        md += "### Recent\n"
        md += summaries.isEmpty ? "_No recent messages found._" : summaries.joined(separator: "\n")

        return ConnectorResult(
            connectorId: id,
            connectorName: name,
            icon: icon,
            answer: md,
            rawData: ["unread": unreadEstimate, "recentIds": recentIds],
            timeRange: intent.timeRange,
            cachedAt: Date()
        )
    }

    // MARK: Helpers

    private func simpleResult(_ text: String, intent: ConnectorIntent, raw: [String: Any]) -> ConnectorResult {
        ConnectorResult(
            connectorId: id, connectorName: name, icon: icon,
            answer: text, rawData: raw,
            timeRange: intent.timeRange, cachedAt: Date()
        )
    }

    /// Very lightweight sender extraction — looks for words after "von"/"from".
    /// Returns the captured phrase or nil.
    private func extractSender(from query: String) -> String? {
        let lower = query.lowercased()
        let markers = ["von ", "from ", "by "]
        for marker in markers {
            if let range = lower.range(of: marker) {
                let tail = query[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                // Stop at the first punctuation / question word.
                let stopChars = CharacterSet(charactersIn: "?.!,;")
                if let stop = tail.rangeOfCharacter(from: stopChars) {
                    return String(tail[..<stop.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
                return tail.isEmpty ? nil : tail
            }
        }
        return nil
    }

    private func cleanFrom(_ raw: String) -> String {
        // "Name <email@example.com>" → "Name" (fallback to email).
        if let open = raw.firstIndex(of: "<") {
            let name = raw[..<open].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return raw
    }

    /// Walk the MIME parts tree and extract the first text/plain body.
    private func extractPlainBody(payload: [String: Any]) -> String {
        if let mime = payload["mimeType"] as? String, mime == "text/plain",
           let bodyObj = payload["body"] as? [String: Any],
           let b64 = bodyObj["data"] as? String,
           let decoded = decodeBase64URL(b64) {
            return decoded
        }
        if let parts = payload["parts"] as? [[String: Any]] {
            for part in parts {
                let got = extractPlainBody(payload: part)
                if !got.isEmpty { return got }
            }
        }
        return ""
    }

    private func decodeBase64URL(_ s: String) -> String? {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str.append("=") }
        guard let data = Data(base64Encoded: str) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
