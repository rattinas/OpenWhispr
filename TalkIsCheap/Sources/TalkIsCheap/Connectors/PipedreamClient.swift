import Foundation
import AuthenticationServices

/// Client for TalkIsCheap Server's Pipedream Connect endpoints. Mirrors
/// the shape of NangoClient so the rest of the app can pick either
/// backend — right now we ship Pipedream for the broader managed OAuth
/// coverage (including Meta Ads / Google Ads / Shopify which Nango
/// requires custom apps for).
@MainActor
final class PipedreamClient: NSObject {
    static let shared = PipedreamClient()
    private override init() { super.init() }

    // MARK: - Base URL / auth

    private static let baseURL = URL(string: "https://talkischeap.app/api")!

    private func authorizedRequest(url: URL, method: String = "GET") -> URLRequest? {
        let token = AppSettings.shared.activationToken
        guard !token.isEmpty else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(LicenseManager.hardwareUUID(), forHTTPHeaderField: "X-Hardware-Id")
        return req
    }

    // MARK: - Errors

    enum PDError: LocalizedError {
        case notLicensed
        case sessionFailed(String)
        case timeout
        case apiError(Int, String)

        var errorDescription: String? {
            switch self {
            case .notLicensed:
                return "You need an active license to connect services."
            case .sessionFailed(let msg): return "Setting up OAuth failed: \(msg)"
            case .timeout: return "Connection timed out — the browser closed before authorization completed."
            case .apiError(let code, let msg): return "Server error \(code): \(msg)"
            }
        }
    }

    // MARK: - Model types

    struct ConnectTokenResponse: Decodable {
        let token: String?
        let connectLinkUrl: String?
        let expiresAt: String?
        let externalUserId: String?
    }

    struct Account: Decodable, Hashable {
        let id: String
        let appSlug: String
        let appName: String
        let appLogo: String?
        let externalUserId: String?
        let healthy: Bool?
        let createdAt: String?
    }

    struct AppInfo: Decodable, Hashable {
        let slug: String
        let name: String
        let logo: String?
        let categories: [String]
        let authType: String
    }

    // MARK: - Connect flow

    /// End-to-end connect flow for a given Pipedream app slug.
    ///
    /// Opens Pipedream's Connect URL in the user's DEFAULT browser
    /// (Safari / Chrome / whatever) rather than ASWebAuthenticationSession.
    /// Reason: Pipedream Connect in development mode requires the user
    /// to be signed into pipedream.com in that browser, and ASWebAuthn's
    /// cookie jar is separate from the system browser on macOS — the
    /// Pipedream session cookie is never picked up, so the Connect UI
    /// rejects the flow with "You must be signed into Pipedream".
    ///
    /// The user's default browser naturally carries their Pipedream
    /// login, so the Connect UI loads immediately. We poll our backend
    /// for up to 3 minutes to detect when they've finished authorising.
    func connect(app: String) async throws -> Account {
        let before = (try? await listAccounts()) ?? []
        let beforeIds = Set(before.map(\.id))

        let session = try await createSession(app: app)
        guard let urlStr = session.connectLinkUrl, let url = URL(string: urlStr) else {
            throw PDError.sessionFailed("Missing connect_link_url")
        }

        // Open in default browser. User's existing Pipedream cookie
        // works automatically; Gmail/Shopify/… OAuth UI uses whatever
        // they're already logged into.
        NSWorkspace.shared.open(url)

        // Poll until the new account appears on our backend, or give up.
        // 3-minute ceiling accounts for "user got distracted, came back".
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            let now = (try? await listAccounts()) ?? []
            if let fresh = now.first(where: { !beforeIds.contains($0.id) }) {
                return fresh
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw PDError.timeout
    }

    // MARK: - Server calls

    private func createSession(app: String?) async throws -> ConnectTokenResponse {
        guard var req = authorizedRequest(
            url: Self.baseURL.appendingPathComponent("pipedream/connect-token"),
            method: "POST"
        ) else { throw PDError.notLicensed }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [:]
        if let app { body["app"] = app }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? "?"
            throw PDError.apiError(http.statusCode, msg.prefix(300).description)
        }
        return try JSONDecoder().decode(ConnectTokenResponse.self, from: data)
    }

    func listAccounts(app: String? = nil) async throws -> [Account] {
        var comps = URLComponents(
            url: Self.baseURL.appendingPathComponent("pipedream/accounts"),
            resolvingAgainstBaseURL: false
        )!
        if let app { comps.queryItems = [URLQueryItem(name: "app", value: app)] }
        guard var req = authorizedRequest(url: comps.url!) else {
            throw PDError.notLicensed
        }
        req.timeoutInterval = 10

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw PDError.apiError(http.statusCode, msg.prefix(300).description)
        }
        struct Wrapper: Decodable { let accounts: [Account] }
        return try JSONDecoder().decode(Wrapper.self, from: data).accounts
    }

    func disconnect(accountId: String) async throws {
        guard var req = authorizedRequest(
            url: Self.baseURL.appendingPathComponent("pipedream/accounts"),
            method: "DELETE"
        ) else { throw PDError.notLicensed }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["accountId": accountId])
        let (_, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw PDError.apiError(http.statusCode, "Disconnect failed")
        }
    }

    func apps(query: String? = nil) async throws -> [AppInfo] {
        var comps = URLComponents(
            url: Self.baseURL.appendingPathComponent("pipedream/apps"),
            resolvingAgainstBaseURL: false
        )!
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            comps.queryItems = [URLQueryItem(name: "q", value: query.trimmingCharacters(in: .whitespaces))]
        }
        guard let req = authorizedRequest(url: comps.url!) else {
            throw PDError.notLicensed
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw PDError.apiError(http.statusCode, msg.prefix(300).description)
        }
        struct Wrapper: Decodable { let apps: [AppInfo] }
        return try JSONDecoder().decode(Wrapper.self, from: data).apps
    }

    // MARK: - Proxy

    /// Make a Pipedream-proxied upstream request.
    /// - Parameters:
    ///   - accountId: The Pipedream account id (apn_…) to use.
    ///   - url:       The full upstream URL (e.g. "https://api.github.com/user/repos").
    ///   - method:    HTTP method (default GET).
    ///   - body:      JSON body for POST/PUT/PATCH.
    func proxy(
        accountId: String,
        url: String,
        method: String = "GET",
        body: Any? = nil
    ) async throws -> Data {
        let httpMethod = method.uppercased() == "GET" ? "GET" : "POST"
        guard var req = authorizedRequest(
            url: Self.baseURL.appendingPathComponent("pipedream/proxy"),
            method: httpMethod
        ) else { throw PDError.notLicensed }
        req.setValue(accountId, forHTTPHeaderField: "X-PD-Account-Id")
        req.setValue(url, forHTTPHeaderField: "X-PD-Url")
        req.setValue(method.uppercased(), forHTTPHeaderField: "X-PD-Method")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        req.timeoutInterval = 30

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw PDError.apiError(http.statusCode, msg.prefix(300).description)
        }
        return data
    }
}

extension PipedreamClient: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            return w
        }
        return ASPresentationAnchor()
    }
}
