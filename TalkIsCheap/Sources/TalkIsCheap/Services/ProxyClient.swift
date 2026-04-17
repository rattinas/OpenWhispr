import Foundation

/// Client for talkischeap.app proxy API (Pro subscribers + Trial users).
/// Forwards STT/Polish/Search calls through our backend so the user doesn't need their own API keys.
enum ProxyClient {
    private static let baseURL = "https://talkischeap.app/api/proxy"

    enum ProxyError: LocalizedError {
        case unauthorized
        case quotaExceeded(used: Int, limit: Int, resetAt: String, reason: String)
        case paymentRequired(reason: String) // Trial exhausted
        case networkError(String)
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "Please reactivate your license"
            case .quotaExceeded(_, let limit, _, _): return "Monthly limit reached (\(limit)). Upgrade or wait for reset."
            case .paymentRequired(let reason): return reason
            case .networkError(let msg): return "Connection error: \(msg)"
            case .serverError(let msg): return "Server error: \(msg)"
            }
        }
    }

    private static func buildRequest(path: String, method: String = "POST") -> URLRequest? {
        guard let url = URL(string: "\(baseURL)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method

        let settings = AppSettings.shared
        request.setValue("Bearer \(settings.activationToken)", forHTTPHeaderField: "Authorization")
        request.setValue(LicenseManager.hardwareUUID(), forHTTPHeaderField: "X-Hardware-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
        return request
    }

    private static func parseError(data: Data, status: Int) -> ProxyError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let errorMsg = json["error"] as? String ?? "Unknown error"

        switch status {
        case 401, 403:
            return .unauthorized
        case 402:
            return .paymentRequired(reason: errorMsg)
        case 429:
            let used = json["used"] as? Int ?? 0
            let limit = json["limit"] as? Int ?? 0
            let resetAt = json["resetAt"] as? String ?? ""
            return .quotaExceeded(used: used, limit: limit, resetAt: resetAt, reason: errorMsg)
        default:
            return .serverError("\(status): \(errorMsg)")
        }
    }

    // MARK: - Transcribe (Groq Whisper)

    static func transcribe(wavData: Data, language: String?, dictionary: String?) async throws -> String {
        guard var request = buildRequest(path: "/transcribe") else {
            throw ProxyError.networkError("Invalid URL")
        }

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()

        // file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)

        // model
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-large-v3\r\n".data(using: .utf8)!)

        // response_format
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)

        // language
        if let lang = language, lang != "auto", !lang.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(lang)\r\n".data(using: .utf8)!)
        }

        // dictionary as initial prompt (custom vocabulary)
        if let dict = dictionary, !dict.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(dict)\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProxyError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 200 {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        throw parseError(data: data, status: httpResponse.statusCode)
    }

    // MARK: - Deepgram token (TalkIsCheap Server)

    /// Mints a short-lived Deepgram scoped key via our server. The client uses
    /// the returned token to open a WebSocket directly to Deepgram — audio
    /// never passes through our server. Each call counts as one dictation.
    static func mintDeepgramToken() async throws -> String {
        guard var request = buildRequest(path: "/deepgram-token") else {
            throw ProxyError.networkError("Invalid URL")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProxyError.networkError("Invalid response")
        }
        if http.statusCode == 200 {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard let token = json?["token"] as? String, !token.isEmpty else {
                throw ProxyError.serverError("Missing token in response")
            }
            return token
        }
        throw parseError(data: data, status: http.statusCode)
    }

    // MARK: - Polish (Claude Haiku)

    static func polish(text: String, systemPrompt: String) async throws -> String {
        guard var request = buildRequest(path: "/polish") else {
            throw ProxyError.networkError("Invalid URL")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let model = AppSettings.shared.highQualityPolish
            ? "claude-sonnet-4-6"
            : "claude-haiku-4-5-20251001"
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": [["role": "user", "content": text]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProxyError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 200 {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let content = json["content"] as? [[String: Any]] ?? []
            return (content.first?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        throw parseError(data: data, status: httpResponse.statusCode)
    }

    // MARK: - Search

    struct SearchResult {
        let answer: String
        let sources: [(title: String, url: String, description: String)]
    }

    static func search(query: String, language: String?) async throws -> SearchResult {
        guard var request = buildRequest(path: "/search") else {
            throw ProxyError.networkError("Invalid URL")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body: [String: Any] = [
            "query": query,
            "model": AppSettings.shared.searchModel,
        ]
        if let lang = language, lang != "auto" {
            body["language"] = lang
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProxyError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 200 {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let answer = json["answer"] as? String ?? ""
            let sourceList = (json["sources"] as? [[String: Any]] ?? []).map { dict in
                (
                    title: dict["title"] as? String ?? "",
                    url: dict["url"] as? String ?? "",
                    description: dict["description"] as? String ?? ""
                )
            }
            return SearchResult(answer: answer, sources: sourceList)
        }
        throw parseError(data: data, status: httpResponse.statusCode)
    }

    // MARK: - Subscription Status

    struct SubscriptionStatus: Decodable {
        let tier: String
        let status: String?
        let trialUsesRemaining: Int
        let currentPeriodEnd: String?
        let usage: Usage
        let limits: Usage
        let resetAt: String

        struct Usage: Decodable {
            let transcribe: Int
            let polish: Int
            let search: Int
            let file_transcribe: Int
        }
    }

    static func fetchStatus() async -> SubscriptionStatus? {
        guard var request = buildRequest(path: "/../subscription/status", method: "GET") else { return nil }
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            return try JSONDecoder().decode(SubscriptionStatus.self, from: data)
        } catch {
            Log.write("fetchStatus failed: \(error)")
            return nil
        }
    }

    // MARK: - Trial Start

    static func startTrial() async -> Bool {
        let hwid = LicenseManager.hardwareUUID()
        let machineName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

        guard let url = URL(string: "https://talkischeap.app/api/trial/start") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "hardwareId": hwid,
            "machineName": machineName,
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return false
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let licenseKey = json["licenseKey"] as? String ?? ""
            let token = json["activationToken"] as? String ?? ""
            let activatedAt = json["activatedAt"] as? String ?? ""
            let trialUses = json["trialUsesRemaining"] as? Int ?? 10

            await MainActor.run {
                let settings = AppSettings.shared
                settings.licenseKey = licenseKey
                settings.activationToken = token
                settings.activatedAt = activatedAt
                settings.tier = "trial"
                settings.trialUsesRemaining = trialUses
                settings.useCloudProxy = true
            }
            Log.write("Trial started: \(licenseKey), \(trialUses) uses remaining")
            return true
        } catch {
            Log.write("startTrial failed: \(error)")
            return false
        }
    }
}
