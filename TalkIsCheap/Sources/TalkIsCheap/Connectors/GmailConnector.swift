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

        // Draft the action for the user to confirm + edit. Don't hit
        // Gmail yet — SearchPanelManager.confirmPending will re-assemble
        // the MIME from the final (possibly edited) field values.
        let isGerman = looksGerman(intent.rawQuery)
        var md = "## ✉️ \(isGerman ? "E-Mail bereit zum Senden" : "Email ready to send")\n\n"
        md += "*\(isGerman ? "Passe die Felder unten an, dann Senden klicken." : "Adjust the fields below, then click Send.")*"

        let fields: [EditableField] = [
            EditableField(key: "to", label: isGerman ? "An" : "To", multiline: false, value: to),
            EditableField(key: "subject", label: isGerman ? "Betreff" : "Subject", multiline: false, value: subject),
            EditableField(key: "body", label: isGerman ? "Nachricht" : "Message", multiline: true, value: body),
        ]
        var hidden: [String: String] = [:]
        if let tid = parsed["threadId"] as? String, !tid.isEmpty {
            hidden["threadId"] = tid
        }

        let pending = PendingAction(
            kind: "gmail.send",
            title: isGerman ? "E-Mail senden" : "Send email",
            appSlug: "gmail",
            endpoint: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
            method: "POST",
            editable: fields,
            hidden: hidden
        )

        return ConnectorResult(
            connectorId: id, connectorName: name, icon: icon,
            answer: md,
            rawData: [
                "to": to, "subject": subject, "body": body,
                "threadId": (parsed["threadId"] as? String) ?? "",
            ],
            timeRange: intent.timeRange,
            cachedAt: Date(),
            pendingActions: [pending]
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

    // MARK: - Smart triage v2 — only real human replies, each its own card

    private func smartTriage(intent: ConnectorIntent) async throws -> ConnectorResult {
        // 1. Know who "me" is so we can skip threads we've already answered.
        let myEmail: String = await {
            guard let data = try? await apiGet(path: "/gmail/v1/users/me/profile"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return "" }
            return (json["emailAddress"] as? String)?.lowercased() ?? ""
        }()

        // 2. Fetch the user's labels — their own organisation system is
        //    the best signal for "what needs attention". If they've
        //    labelled something 'needs answer', 'dringend', 'wichtig',
        //    'todo', 'wait', 'follow up' — that's ground truth.
        let labelData = try? await apiGet(path: "/gmail/v1/users/me/labels")
        let labelsJson = (try? labelData.flatMap { try JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
        let rawLabels = (labelsJson?["labels"] as? [[String: Any]]) ?? []
        let labels: [(id: String, name: String)] = rawLabels.compactMap {
            guard let id = $0["id"] as? String, let name = $0["name"] as? String else { return nil }
            return (id, name)
        }
        let actionableHints = [
            "answer", "reply", "respond",            // EN intent
            "urgent", "action", "todo", "to-do", "to do",
            "follow up", "follow-up", "followup",
            "wait", "waiting",
            "antwort", "antworten", "beantwort",     // DE intent
            "wichtig", "dringend", "aufgabe",
            "erledig", "rückmeld",
            "priority", "priorität",
        ]
        // 2a. User's explicit choice takes precedence. If they've picked
        //     specific labels in Settings → Gmail triage, use ONLY those
        //     (intersect with actually-existing labels so a stale choice
        //     doesn't break the query).
        let explicitSelection = AppSettings.shared.gmailTriageLabelList
        let availableNames = Set(labels.map { $0.name })
        let actionableLabelNames: [String]
        if !explicitSelection.isEmpty {
            actionableLabelNames = explicitSelection.filter { availableNames.contains($0) }
        } else {
            actionableLabelNames = labels
                .map { $0.name }
                .filter { label in
                    let n = label.lowercased()
                    return actionableHints.contains { n.contains($0) }
                }
        }
        Log.write("Gmail triage: using labels \(actionableLabelNames) (explicit=\(!explicitSelection.isEmpty))")

        // 3. Build the Gmail search query:
        //    a) user's own actionable labels (strongest signal)
        //    b) Gmail's IS_IMPORTANT system flag (Gmail's own AI)
        //    c) unread in inbox (fallback — only if no stronger signal hits)
        //    MINUS automated senders + low-signal categories.
        var queryParts: [String] = []
        var orClauses: [String] = []
        for name in actionableLabelNames {
            let escaped = name.contains(" ") ? "\"\(name)\"" : name
            orClauses.append("label:\(escaped)")
        }
        // Always include unread + important as OR signals so we don't
        // return an empty result if the user hasn't labelled anything yet.
        orClauses.append("is:unread")
        orClauses.append("is:important")
        if !orClauses.isEmpty {
            queryParts.append("(\(orClauses.joined(separator: " OR ")))")
        }
        queryParts.append("in:inbox")
        queryParts.append("-category:promotions")
        queryParts.append("-category:updates")
        queryParts.append("-category:forums")
        queryParts.append("-category:social")
        let excludedFroms = [
            "noreply", "no-reply", "donotreply", "do-not-reply",
            "notifications", "notification", "notify",
            "mailer-daemon", "postmaster",
            "calendar-notification@google.com",
            "bounces", "reply+",
            "newsletter",
        ]
        for f in excludedFroms { queryParts.append("-from:\(f)") }
        let gmailQuery = queryParts.joined(separator: " ")
        let encodedQ = gmailQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? gmailQuery

        // 3. Use THREADS (not messages) so we can check the last-sender of
        //    each conversation and skip threads where I already replied.
        let listData = try await apiGet(path: "/gmail/v1/users/me/threads?maxResults=25&q=\(encodedQ)")
        guard let listJson = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
              let threadStubs = listJson["threads"] as? [[String: Any]], !threadStubs.isEmpty
        else {
            let isGerman = looksGerman(intent.rawQuery)
            return ConnectorResult(
                connectorId: id, connectorName: name, icon: icon,
                answer: "## 📭 " + (isGerman ? "Keine dringenden Mails" : "Inbox is clear") + "\n\n" + (isGerman ? "Nichts Unbeantwortetes im Posteingang — abgesehen von automatischen Mails." : "Nothing waiting on a real reply — automated notifications filtered out."),
                rawData: ["excluded": excludedFroms],
                timeRange: intent.timeRange, cachedAt: Date()
            )
        }

        // 4. For each thread: fetch full, check last sender ≠ me, keep body.
        //    Also compute a priority score based on labels + signals.
        struct ThreadSnapshot {
            let threadId: String
            let messageId: String
            let from: String
            let fromEmail: String
            let subject: String
            let date: String
            let body: String
            let score: Int
            let matchedLabels: [String]
        }
        // Pre-compute the set of actionable label names (lowercased) for
        // fast membership checks inside the task group.
        let actionableLabelSet = Set(actionableLabelNames.map { $0.lowercased() })
        let labelIdToName = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0.name) })
        let threadIds = threadStubs.prefix(25).compactMap { $0["id"] as? String }
        var candidates: [ThreadSnapshot] = []
        try await withThrowingTaskGroup(of: ThreadSnapshot?.self) { group in
            for tid in threadIds {
                group.addTask { [self] in
                    guard let raw = try? await self.apiGet(path: "/gmail/v1/users/me/threads/\(tid)?format=full"),
                          let thread = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                          let messages = thread["messages"] as? [[String: Any]],
                          let last = messages.last
                    else { return nil }
                    let payload = last["payload"] as? [String: Any] ?? [:]
                    let headers = (payload["headers"] as? [[String: Any]]) ?? []
                    func header(_ name: String) -> String {
                        headers.first { ($0["name"] as? String)?.lowercased() == name.lowercased() }?["value"] as? String ?? ""
                    }
                    let from = header("From")
                    let bareEmail = self.extractBareEmail(from: from)?.lowercased() ?? ""
                    if !myEmail.isEmpty, bareEmail == myEmail { return nil }
                    if self.looksAutomated(from: from, email: bareEmail) { return nil }

                    // Header-based bulk / notification detection. Every
                    // well-behaved newsletter / system mail carries one of
                    // these — they're the clearest "do not reply" signal
                    // the internet has.
                    let listUnsubscribe = header("List-Unsubscribe")
                    let autoSubmitted = header("Auto-Submitted")
                    let precedence = header("Precedence").lowercased()
                    let xAutoResponse = header("X-Auto-Response-Suppress")
                    if !listUnsubscribe.isEmpty { return nil }
                    if !autoSubmitted.isEmpty, autoSubmitted.lowercased() != "no" { return nil }
                    if ["bulk", "list", "junk"].contains(precedence) { return nil }
                    if !xAutoResponse.isEmpty { return nil }

                    let body = self.extractPlainBody(payload: payload).trimmingCharacters(in: .whitespacesAndNewlines)
                    if body.isEmpty { return nil }

                    // Gmail labels on the *last* message (most relevant).
                    let labelIds = (last["labelIds"] as? [String]) ?? []
                    let labelNamesOnMsg = labelIds.compactMap { labelIdToName[$0] }
                    let matched = labelNamesOnMsg.filter { actionableLabelSet.contains($0.lowercased()) }

                    // Scoring: label hits dominate, then system signals,
                    // then body-content signals. Higher = more urgent.
                    var score = 0
                    score += matched.count * 12                  // user urgency labels
                    if labelIds.contains("STARRED") { score += 6 }
                    if labelIds.contains("IMPORTANT") { score += 4 }
                    if labelIds.contains("UNREAD") { score += 2 }
                    let lowered = body.lowercased()
                    if body.contains("?") { score += 3 }
                    for ask in ["please", "bitte", "können sie", "könnten sie", "would you", "could you", "let me know", "dringend", "wichtig"] {
                        if lowered.contains(ask) { score += 2; break }
                    }
                    // Single-message threads (no back-and-forth yet) are more
                    // likely to need a reply than long chains.
                    if messages.count == 1 { score += 1 }

                    return ThreadSnapshot(
                        threadId: tid,
                        messageId: (last["id"] as? String) ?? "",
                        from: from,
                        fromEmail: bareEmail,
                        subject: header("Subject"),
                        date: header("Date"),
                        body: body,
                        score: score,
                        matchedLabels: matched
                    )
                }
            }
            for try await s in group { if let s { candidates.append(s) } }
        }

        // 5. Rank by score (labels weigh most), cap to top 3.
        candidates.sort { $0.score > $1.score }
        let topN = Array(candidates.prefix(3))

        if topN.isEmpty {
            let isGerman = looksGerman(intent.rawQuery)
            return ConnectorResult(
                connectorId: id, connectorName: name, icon: icon,
                answer: "## 📭 " + (isGerman ? "Keine offenen Antworten" : "Nothing waiting for a reply") + "\n\n" + (isGerman ? "Alle Threads sind bereits beantwortet oder automatisch." : "Every unread thread is either automated or already answered by you."),
                rawData: ["filtered": candidates.count],
                timeRange: intent.timeRange, cachedAt: Date()
            )
        }

        // 6. For each: one Claude Haiku call returning BOTH a one-line
        //    summary of what the sender is asking + a drafted reply.
        //    Single round-trip keeps latency < 2s total even with 3 emails.
        let isGerman = looksGerman(intent.rawQuery)
        let draftSystem = """
        You process an incoming email. Return ONLY strict JSON:
        {
          "summary": string,  // ONE sentence: what the sender is asking
                              // / needs / wants. Match their language.
          "draft": string     // reply body only — no subject, no
                              // 'Here is a draft:' preamble, no
                              // greeting unless the original had one.
                              // Keep it 2–4 sentences, polite, directly
                              // addressing any question. Same language.
        }
        """
        struct DraftedReply {
            let snapshot: ThreadSnapshot
            let summary: String
            let draft: String
        }
        var drafts: [DraftedReply] = []
        try await withThrowingTaskGroup(of: DraftedReply?.self) { group in
            for snap in topN {
                group.addTask {
                    let prompt = """
                    Email received:

                    From: \(snap.from)
                    Subject: \(snap.subject)

                    \(snap.body.prefix(2500))
                    """
                    let raw = (try? await ProxyClient.polish(
                        text: prompt,
                        systemPrompt: draftSystem,
                        model: "claude-haiku-4-5-20251001"
                    )) ?? ""
                    let cleaned = raw
                        .replacingOccurrences(of: "```json", with: "")
                        .replacingOccurrences(of: "```", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    var summary = ""
                    var draft = ""
                    if let data = cleaned.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        summary = (json["summary"] as? String) ?? ""
                        draft = (json["draft"] as? String) ?? ""
                    }
                    // Graceful fallback if Claude didn't return JSON.
                    if draft.isEmpty { draft = cleaned }
                    return DraftedReply(snapshot: snap, summary: summary, draft: draft)
                }
            }
            for try await d in group { if let d { drafts.append(d) } }
        }
        drafts.sort { a, b in
            topN.firstIndex { $0.threadId == a.snapshot.threadId } ?? 0
                < topN.firstIndex { $0.threadId == b.snapshot.threadId } ?? 0
        }

        // 7. Build one PendingAction per drafted reply so each email
        //    becomes its own editable card in the UI.
        let pendings: [PendingAction] = drafts.map { d in
            let snap = d.snapshot
            let subjectBase = snap.subject
            let replySubject = subjectBase.lowercased().hasPrefix("re:") ? subjectBase : "Re: \(subjectBase)"
            let toAddr = snap.fromEmail.isEmpty ? snap.from : snap.fromEmail
            let fields: [EditableField] = [
                EditableField(key: "to", label: isGerman ? "An" : "To", multiline: false, value: toAddr),
                EditableField(key: "subject", label: isGerman ? "Betreff" : "Subject", multiline: false, value: replySubject),
                EditableField(key: "body", label: isGerman ? "Nachricht" : "Message", multiline: true, value: d.draft),
            ]
            let baseTitle = isGerman ? "Antwort senden an \(cleanFrom(snap.from))" : "Reply to \(cleanFrom(snap.from))"
            let fullTitle: String
            if !snap.matchedLabels.isEmpty {
                let joined = snap.matchedLabels.joined(separator: ", ")
                fullTitle = "\(baseTitle)  ·  🏷 \(joined)"
            } else {
                fullTitle = baseTitle
            }
            // Compose the read-only summary shown at the top of the card.
            // Keeps the "what are you replying to" context visible without
            // the user having to click through.
            let dateStr = snap.date.isEmpty ? "" : " · \(snap.date)"
            let summary = """
            **\(snap.subject)**  —  \(self.cleanFrom(snap.from))\(dateStr)

            \(d.summary.isEmpty ? String(snap.body.prefix(240)) : d.summary)
            """

            return PendingAction(
                kind: "gmail.send",
                title: fullTitle,
                appSlug: "gmail",
                endpoint: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
                method: "POST",
                editable: fields,
                hidden: [
                    "threadId": snap.threadId,
                    "originalSubject": snap.subject,
                    "originalFrom": snap.from,
                    "originalBody": String(snap.body.prefix(3000)),
                    "matchedLabels": snap.matchedLabels.joined(separator: ", "),
                ],
                summary: summary
            )
        }

        // 8. Short header — the cards do the rest.
        let headline: String
        if isGerman {
            headline = drafts.count == 1
                ? "📬 1 Mail wartet auf deine Antwort"
                : "📬 \(drafts.count) Mails warten auf deine Antwort"
        } else {
            headline = drafts.count == 1
                ? "📬 1 email waiting for your reply"
                : "📬 \(drafts.count) emails waiting for your reply"
        }
        var md = "## \(headline)\n\n"
        md += isGerman
            ? "Unten siehst du für jede einen editierbaren Antwort-Entwurf. Tweake den Text und klick **Antwort senden**."
            : "A draft reply is prepared for each — tweak the text and hit **Send reply**."

        // Context for follow-up chat ("mach die zweite kürzer", etc.).
        let ctx: [String: Any] = [
            "drafts": drafts.map { d in
                [
                    "from": d.snapshot.from,
                    "subject": d.snapshot.subject,
                    "date": d.snapshot.date,
                    "body": d.snapshot.body,
                    "draft": d.draft,
                ]
            }
        ]

        return ConnectorResult(
            connectorId: id, connectorName: name, icon: icon,
            answer: md,
            rawData: ctx,
            timeRange: intent.timeRange,
            cachedAt: Date(),
            pendingActions: pendings
        )
    }

    nonisolated private func looksAutomated(from raw: String, email: String) -> Bool {
        let sig = (raw + " " + email).lowercased()
        let markers = [
            "noreply", "no-reply", "donotreply", "do-not-reply",
            "notifications@", "notification@", "notify@",
            "mailer-daemon", "postmaster", "bounces",
            "automated", "auto-reply", "no reply",
        ]
        return markers.contains { sig.contains($0) }
    }

    // Keep the old smartTriage signature as a no-op to avoid breaking
    // callers that imported it — just forwards to the new impl.
    @MainActor
    private func smartTriageLegacy(intent: ConnectorIntent) async throws -> ConnectorResult {
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
