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

        // Heuristic: if the query mentions a sender name/email, search for that.
        let sender = extractSender(from: intent.rawQuery)

        if let sender {
            return try await lastMessageFromSender(sender, intent: intent)
        }
        return try await recentInboxSummary(intent: intent)
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
