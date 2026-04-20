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

        // AGENT path — user wants to SEND or REPLY to email.
        // Handled before triage because "antworte" is ambiguous: either
        // "show me what needs answering" (triage) OR "send this reply"
        // (agent). The presence of an imperative-send phrase + concrete
        // content ("mit: …", "mit dem text", "saying …") tells us it's
        // the agent flow.
        let sendImperatives = [
            "schick", "sende", "verschick", "schreib ",
            "send an email", "send a mail", "send email", "send mail",
            "compose an email", "compose a mail",
        ]
        let replyImperatives = [
            "antworte ", "antworte auf", "antworte der", "antworte dem",
            "antworte an ", "beantworte die", "beantworte den", "beantworte dem",
            "reply to ", "reply with ", "respond to ",
        ]
        let isSend = sendImperatives.contains { q.contains($0) }
        let isReply = replyImperatives.contains { q.contains($0) }
        if isSend || isReply {
            return try await sendEmailAgent(intent: intent, isReply: isReply)
        }

        // Fire triage whenever the user mentions emails AND any action
        // word — covers "auf welche Mails muss ich antworten", "welche
        // emails sind wichtig", "should I reply to anything", etc.
        let emailKeywords = ["mail", "mails", "email", "emails", "inbox", "posteingang", "nachricht", "messages"]
        let actionKeywords = [
            "antworten", "beantworten", "reply", "answer", "respond",
            "wichtig", "urgent", "dringend", "priority", "priorisieren",
            "muss", "should", "action", "folgen", "drauf", "worauf",
            "welche", "which", "wartet", "wait"
        ]
        let hasEmail = emailKeywords.contains { q.contains($0) }
        let hasAction = actionKeywords.contains { q.contains($0) }
        if hasEmail && hasAction {
            return try await smartTriage(intent: intent)
        }

        // Heuristic: if the query mentions a sender name/email, search for that.
        let sender = extractSender(from: intent.rawQuery)
        if let sender {
            return try await lastMessageFromSender(sender, intent: intent)
        }
        return try await recentInboxSummary(intent: intent)
    }

    // MARK: - Send / Reply agent

    private func sendEmailAgent(intent: ConnectorIntent, isReply: Bool) async throws -> ConnectorResult {
        // If this is a reply and the sender is named ("antworte Moritz"),
        // pull the latest message from that sender so Claude has the thread
        // context.
        var threadContext = ""
        var suggestedThreadId: String?
        var suggestedToEmail: String?
        var suggestedOriginalSubject: String?

        if isReply, let sender = extractSender(from: intent.rawQuery) {
            let q = "from:\"\(sender)\""
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            if let listData = try? await apiGet(path: "/gmail/v1/users/me/messages?maxResults=1&q=\(encoded)"),
               let listJson = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
               let msgs = listJson["messages"] as? [[String: Any]], let first = msgs.first,
               let mid = first["id"] as? String,
               let msgData = try? await apiGet(path: "/gmail/v1/users/me/messages/\(mid)?format=full"),
               let msg = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any] {
                suggestedThreadId = msg["threadId"] as? String
                let headers = ((msg["payload"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
                func header(_ name: String) -> String {
                    headers.first { ($0["name"] as? String)?.lowercased() == name.lowercased() }?["value"] as? String ?? ""
                }
                let from = header("From")
                suggestedToEmail = extractBareEmail(from: from)
                suggestedOriginalSubject = header("Subject")
                let body = extractPlainBody(payload: msg["payload"] as? [String: Any] ?? [:])
                let trimmed = body.count > 2000 ? String(body.prefix(2000)) + "…" : body
                threadContext = """
                ## Original email being replied to

                **From:** \(from)
                **Subject:** \(header("Subject"))
                **Date:** \(header("Date"))

                \(trimmed)
                """
            }
        }

        let nowISO = ISO8601DateFormatter().string(from: Date())
        let system = """
        You extract email-send parameters from a natural-language voice \
        command. Return ONLY strict JSON:
        {
          "mode": "reply" | "new",
          "to": string,        // recipient email address
          "subject": string,   // use "Re: <original>" for replies
          "body": string,      // final body text — polish the user's spoken
                               // content into a clean, professional message,
                               // but keep the tone and language they used
          "threadId": string | null   // required for replies
        }
        Current moment: \(nowISO). If the user only said "ja passt" or
        similar short content, produce a short reply in the same language.
        Do not invent recipient addresses — if unsure, copy from the
        context below. If 'mode' is 'reply', copy the threadId from the
        original email exactly.
        """

        var userContent = "**User command:** \(intent.rawQuery)\n\n"
        if !threadContext.isEmpty { userContent += threadContext + "\n\n" }
        if let to = suggestedToEmail { userContent += "Suggested recipient: \(to)\n" }
        if let tid = suggestedThreadId { userContent += "Suggested threadId: \(tid)\n" }
        if let subj = suggestedOriginalSubject, !subj.isEmpty {
            userContent += "Original subject (prefix with Re:): \(subj)\n"
        }

        let extracted = try await ProxyClient.polish(
            text: userContent,
            systemPrompt: system,
            model: "claude-haiku-4-5-20251001"
        )
        let cleanJSON = extracted
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleanJSON.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let to = parsed["to"] as? String,
              let subject = parsed["subject"] as? String,
              let body = parsed["body"] as? String,
              !to.isEmpty
        else {
            return ConnectorResult(
                connectorId: id, connectorName: name, icon: icon,
                answer: "⚠️ Ich konnte nicht rausfinden, an wen ich die Mail schicken soll. Sag z.B.: \"Antworte auf die Mail von Moritz mit: ja passt\" oder \"Schick alex@beispiel.de eine Mail, Betreff Lunch, Text: morgen 12 Uhr passt?\".\n\nExtracted: \(cleanJSON.prefix(400))",
                rawData: ["extracted": cleanJSON],
                timeRange: intent.timeRange, cachedAt: Date()
            )
        }

        // Build RFC 2822 MIME text and base64url encode for Gmail API.
        var mime = ""
        mime += "To: \(to)\r\n"
        mime += "Subject: \(subject)\r\n"
        mime += "Content-Type: text/plain; charset=UTF-8\r\n"
        mime += "\r\n"
        mime += body
        let raw = Data(mime.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var sendBody: [String: Any] = ["raw": raw]
        if let tid = parsed["threadId"] as? String, !tid.isEmpty {
            sendBody["threadId"] = tid
        }

        let sentData = try await pipedreamProxy(
            url: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
            method: "POST",
            body: sendBody
        )
        guard let sentJson = try? JSONSerialization.jsonObject(with: sentData) as? [String: Any] else {
            throw ConnectorError.parseError("Send response unparseable")
        }
        if let err = sentJson["error"] as? [String: Any],
           let msg = err["message"] as? String {
            throw ConnectorError.apiError("Gmail: \(msg)")
        }

        let isGerman = looksGerman(intent.rawQuery)
        let sentId = sentJson["id"] as? String ?? ""
        var md = "## ✅ \(isGerman ? "E-Mail gesendet" : "Email sent")\n\n"
        md += "**An:** \(to)\n"
        md += "**\(isGerman ? "Betreff" : "Subject"):** \(subject)\n\n"
        md += body
        if !sentId.isEmpty {
            md += "\n\n[\(isGerman ? "In Gmail öffnen" : "Open in Gmail")](https://mail.google.com/mail/u/0/#sent/\(sentId))"
        }

        return ConnectorResult(
            connectorId: id, connectorName: name, icon: icon,
            answer: md,
            rawData: [
                "sentId": sentId,
                "to": to, "subject": subject, "body": body,
                "threadId": (parsed["threadId"] as? String) ?? "",
            ],
            timeRange: intent.timeRange,
            cachedAt: Date()
        )
    }

    nonisolated private func extractBareEmail(from rfc5322: String) -> String? {
        // "Name <email@example.com>" → "email@example.com"
        if let open = rfc5322.firstIndex(of: "<"),
           let close = rfc5322[open...].firstIndex(of: ">") {
            return String(rfc5322[rfc5322.index(after: open)..<close])
        }
        // Already plain
        if rfc5322.contains("@") { return rfc5322.trimmingCharacters(in: .whitespaces) }
        return nil
    }

    nonisolated private func looksGerman(_ s: String) -> Bool {
        let q = s.lowercased()
        let markers = ["antworte", "schick", "sende", "schreib", "heute", "morgen", "einen", "eine", "mit ", "mir"]
        return markers.contains { q.contains($0) }
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

        // Fetch FULL message data (not just metadata) for each message so
        // Claude has actual body text to reason over. Without bodies it
        // can only recite subject lines, and later "draft a reply" in
        // the follow-up chat has nothing to base the reply on.
        struct InboxMsg {
            let id: String
            let from: String
            let subject: String
            let snippet: String
            let date: String
            let labelNames: [String]
            let isUnread: Bool
            let body: String
        }
        let ids = messageStubs.prefix(15).compactMap { $0["id"] as? String }
        var messages: [InboxMsg] = []
        try await withThrowingTaskGroup(of: (Int, InboxMsg?).self) { group in
            for (idx, id) in ids.enumerated() {
                group.addTask { [self] in
                    let path = "/gmail/v1/users/me/messages/\(id)?format=full"
                    guard let raw = try? await self.apiGet(path: path),
                          let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
                    else { return (idx, nil) }
                    let payload = obj["payload"] as? [String: Any] ?? [:]
                    let headers = (payload["headers"] as? [[String: Any]]) ?? []
                    func header(_ name: String) -> String {
                        headers.first { ($0["name"] as? String)?.lowercased() == name.lowercased() }?["value"] as? String ?? ""
                    }
                    let labelIds = (obj["labelIds"] as? [String]) ?? []
                    let names = labelIds.compactMap { labelNameById[$0] }
                    let body = self.extractPlainBody(payload: payload)
                    let snippet = (obj["snippet"] as? String) ?? ""
                    return (idx, InboxMsg(
                        id: id,
                        from: header("From"),
                        subject: header("Subject").isEmpty ? "(no subject)" : header("Subject"),
                        snippet: snippet,
                        date: header("Date"),
                        labelNames: names,
                        isUnread: labelIds.contains("UNREAD"),
                        body: body
                    ))
                }
            }
            // Collect in fetch order then sort back to original index so the
            // list reflects Gmail's recency ordering regardless of task
            // completion order.
            var collected: [(Int, InboxMsg)] = []
            for try await pair in group {
                if let msg = pair.1 { collected.append((pair.0, msg)) }
            }
            messages = collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        // Build Claude context + ask for a triage.
        var ctx = "Here's a snapshot of the user's inbox with full email bodies. Analyse it and answer their question.\n\n"
        ctx += "## Message list (ranked by Gmail recency within the search scope)\n\n"
        for (i, m) in messages.enumerated() {
            ctx += "### [\(i + 1)] \(m.subject)\n"
            ctx += "- **From:** \(cleanFrom(m.from))\n"
            ctx += "- **Date:** \(m.date)\n"
            if !m.labelNames.isEmpty {
                ctx += "- **Labels:** \(m.labelNames.joined(separator: ", "))\n"
            }
            ctx += "- **Unread:** \(m.isUnread ? "yes" : "no")\n\n"
            let bodyText = m.body.isEmpty ? m.snippet : m.body
            let cleaned = bodyText
                .replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmed = cleaned.count > 1500 ? String(cleaned.prefix(1500)) + "\n[…truncated]" : cleaned
            ctx += "Body:\n\(trimmed)\n\n"
        }

        let systemPrompt = """
        You are a voice-first email triage assistant. The user asks a \
        natural-language question about their inbox (e.g. "welche mails \
        muss ich beantworten?", "was ist wichtig?"). You have the full \
        text of their 15 most relevant emails — use it.

        CRITICAL:
        - Respond in the EXACT SAME LANGUAGE as the user's question. If \
          the question is in German, reply in German. English → English. \
          Never switch mid-answer.
        - Pick the top 3–5 truly urgent items. Stay focused; skip the rest.
        - NUMBER each item [1], [2], [3] matching the message list so the \
          user can say "reply to #2" or "more on #1" later.
        - For each item: one line on who sent it + what they need + why \
          it's urgent. Quote ≤15 words from the body if it clarifies.
        - When the body clearly asks a question or requests an action, \
          include a short suggested reply draft (2–4 lines) under the \
          item, marked "Vorschlag:" / "Suggested reply:" in the user's \
          language.
        - If the query is open-ended ("was sollte ich zuerst angehen"), \
          still produce the numbered list + suggested replies.
        - Don't invent content. Empty of urgent items → say so in one \
          sentence.
        - Output clean Markdown. Bold senders. Use bullet sub-lines \
          sparingly.
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

        // Pass the FULL context forward to follow-up chat so "draft reply
        // to #2" or "make the tone friendlier" has the original email to
        // work from.
        let rawContext: [String: Any] = [
            "messages": messages.map { m in
                [
                    "index": (messages.firstIndex(where: { $0.id == m.id }) ?? 0) + 1,
                    "from": m.from,
                    "subject": m.subject,
                    "date": m.date,
                    "labels": m.labelNames,
                    "unread": m.isUnread,
                    "body": m.body.isEmpty ? m.snippet : m.body,
                ]
            }
        ]

        return ConnectorResult(
            connectorId: id,
            connectorName: name,
            icon: icon,
            answer: answer,
            rawData: rawContext,
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

    nonisolated private func cleanFrom(_ raw: String) -> String {
        // "Name <email@example.com>" → "Name" (fallback to email).
        if let open = raw.firstIndex(of: "<") {
            let name = raw[..<open].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return raw
    }

    /// Walk the MIME parts tree and extract the first text/plain body.
    nonisolated private func extractPlainBody(payload: [String: Any]) -> String {
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

    nonisolated private func decodeBase64URL(_ s: String) -> String? {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str.append("=") }
        guard let data = Data(base64Encoded: str) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
