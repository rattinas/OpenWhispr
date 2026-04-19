import Foundation
import AuthenticationServices

/// Thin client for talking to TalkIsCheap Server's Nango-backed endpoints.
///
/// Never talks to api.nango.dev directly — all requests are tunneled
/// through our server so the Nango secret key never leaves Vercel.
///
/// Public-facing API:
///   - `connect(integrationKey:)` — opens OAuth in ASWebAuthenticationSession,
///     returns the established `connectionId`.
///   - `listConnections(integrationKey:)` — for polling after Connect UI.
///   - `proxy(integrationKey:connectionId:path:method:body:)` — generic
///     upstream API call with Nango-injected auth.
///   - `disconnect(integrationKey:connectionId:)` — revoke a connection.
@MainActor
final class NangoClient: NSObject {
    static let shared = NangoClient()
    private override init() { super.init() }

    // MARK: - Auth header

    private func authHeader() -> String? {
        let token = AppSettings.shared.activationToken
        return token.isEmpty ? nil : "Bearer \(token)"
    }

    /// All our authenticated endpoints require an X-Hardware-Id alongside
    /// the Bearer token (same activation token format as the proxy). Wrap
    /// URLRequest construction so every call sends both.
    private func authorizedRequest(url: URL, method: String = "GET") -> URLRequest? {
        guard let auth = authHeader() else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue(LicenseManager.hardwareUUID(), forHTTPHeaderField: "X-Hardware-Id")
        return req
    }

    private static let baseURL = URL(string: "https://talkischeap.app/api")!
    private func baseURL() -> URL { Self.baseURL }

    // MARK: - Connect flow

    struct SessionResponse: Decodable {
        let connectLink: String?
        let expiresAt: String?
        let sessionToken: String?
        let endUserId: String?
    }

    enum NangoError: LocalizedError {
        case notLicensed
        case sessionFailed(String)
        case authCancelled
        case authFailed(String)
        case timeout
        case apiError(Int, String)

        var errorDescription: String? {
            switch self {
            case .notLicensed:
                return "You need an active license to connect services."
            case .sessionFailed(let msg): return "Setting up OAuth failed: \(msg)"
            case .authCancelled: return "Authorization cancelled."
            case .authFailed(let msg): return "Authorization failed: \(msg)"
            case .timeout: return "Connection timed out — the browser closed before authorization completed."
            case .apiError(let code, let msg): return "Server error \(code): \(msg)"
            }
        }
    }

    /// End-to-end connect flow. Returns the Nango `connectionId` once the
    /// user has successfully authorized via the web UI.
    func connect(integrationKey: String) async throws -> String {
        // 1. Snapshot existing connections so we can tell which one is new.
        let existingBefore = try await listConnections(integrationKey: integrationKey)
        let existingIds = Set(existingBefore.map(\.connectionId))

        // 2. Ask our server for a Connect session.
        let session = try await createSession(integrationKey: integrationKey)
        guard let linkStr = session.connectLink, let url = URL(string: linkStr) else {
            throw NangoError.sessionFailed("Missing connect_link")
        }

        // 3. Open Nango's Connect UI in ASWebAuthenticationSession. Since
        //    Nango's hosted Connect UI doesn't redirect to a custom URL
        //    scheme (it's a web-only SPA that shows a success screen), we
        //    use a bogus callbackURLScheme — the session will error/cancel
        //    when the user dismisses the window, and we then poll our
        //    backend to see if the connection appeared.
        try await withUnsafeThrowingContinuation { (cont: UnsafeContinuation<Void, Error>) in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "talkischeap-never-fires"
            ) { _, _ in
                // We don't use the callback — we detect success via polling.
                // Nango's web UI never hits a custom scheme, so this closure
                // only fires when the user closes the window.
                cont.resume()
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                cont.resume(throwing: NangoError.authFailed("Browser session failed to start"))
            }
        }

        // 4. Poll for the new connection (with a short grace window for
        //    Nango's webhook to persist).
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let now = try await listConnections(integrationKey: integrationKey)
            if let fresh = now.first(where: { !existingIds.contains($0.connectionId) }) {
                return fresh.connectionId
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        throw NangoError.timeout
    }

    // MARK: - Server calls

    private func createSession(integrationKey: String) async throws -> SessionResponse {
        guard var req = authorizedRequest(
            url: baseURL().appendingPathComponent("nango/session"),
            method: "POST"
        ) else { throw NangoError.notLicensed }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["integrationKey": integrationKey])
        req.timeoutInterval = 15

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? "?"
            throw NangoError.apiError(http.statusCode, msg.prefix(300).description)
        }
        return try JSONDecoder().decode(SessionResponse.self, from: data)
    }

    struct Connection: Decodable {
        let connectionId: String
        let integrationKey: String?
        let createdAt: String?
    }

    func listConnections(integrationKey: String? = nil) async throws -> [Connection] {
        var comps = URLComponents(url: baseURL().appendingPathComponent("nango/connection"), resolvingAgainstBaseURL: false)!
        if let key = integrationKey {
            comps.queryItems = [URLQueryItem(name: "integrationKey", value: key)]
        }
        guard var req = authorizedRequest(url: comps.url!) else {
            throw NangoError.notLicensed
        }
        req.timeoutInterval = 10

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? "?"
            throw NangoError.apiError(http.statusCode, msg.prefix(300).description)
        }
        struct Wrapper: Decodable { let connections: [Connection] }
        return try JSONDecoder().decode(Wrapper.self, from: data).connections
    }

    func disconnect(integrationKey: String, connectionId: String) async throws {
        guard var req = authorizedRequest(
            url: baseURL().appendingPathComponent("nango/connection"),
            method: "DELETE"
        ) else { throw NangoError.notLicensed }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "integrationKey": integrationKey,
            "connectionId": connectionId,
        ])
        let (_, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw NangoError.apiError(http.statusCode, "Disconnect failed")
        }
    }

    // MARK: - Proxy a request through Nango

    /// Make a Nango-proxied API call.
    /// - Parameters:
    ///   - integrationKey: Nango integration's unique_key
    ///   - connectionId:   Nango connection_id
    ///   - path:           Upstream path (e.g. "/user/repos" for GitHub)
    ///   - method:         HTTP method (default GET)
    ///   - body:           JSON body (for POST/PUT/PATCH)
    func proxy(
        integrationKey: String,
        connectionId: String,
        path: String,
        method: String = "GET",
        body: Any? = nil
    ) async throws -> Data {
        let httpMethod = method.uppercased() == "GET" ? "GET" : "POST"
        guard var req = authorizedRequest(
            url: baseURL().appendingPathComponent("nango/proxy"),
            method: httpMethod
        ) else { throw NangoError.notLicensed }
        req.setValue(integrationKey, forHTTPHeaderField: "X-Nango-Integration")
        req.setValue(connectionId, forHTTPHeaderField: "X-Nango-Connection-Id")
        req.setValue(path, forHTTPHeaderField: "X-Nango-Path")
        req.setValue(method.uppercased(), forHTTPHeaderField: "X-Nango-Method")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        req.timeoutInterval = 30

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NangoError.apiError(http.statusCode, msg.prefix(300).description)
        }
        return data
    }

    // MARK: - Integrations catalog (dynamic)

    struct CatalogEntry: Decodable, Hashable {
        let uniqueKey: String
        let provider: String
        let displayName: String
        let logo: String?
        let category: String?
        let connected: Bool
        let connectionId: String?
    }

    /// Lists every integration configured in the Nango project, annotated
    /// with whether *this licensee* is already connected. One call replaces
    /// our hard-coded connector list so adding a service in the Nango
    /// dashboard instantly shows up in the app.
    func catalog() async throws -> [CatalogEntry] {
        guard let req = authorizedRequest(url: baseURL().appendingPathComponent("nango/catalog")) else {
            throw NangoError.notLicensed
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NangoError.apiError(http.statusCode, msg.prefix(300).description)
        }
        struct Wrapper: Decodable { let integrations: [CatalogEntry] }
        return try JSONDecoder().decode(Wrapper.self, from: data).integrations
    }

    // MARK: - Provider catalogue (all 761 Nango-supported services)

    struct ProviderInfo: Decodable, Hashable {
        let name: String
        let displayName: String
        let logoUrl: String?
        let categories: [String]
        let authMode: String
        let docs: String?
    }

    /// Lists every provider Nango supports — used so the user can "Add a
    /// new service" from inside the app instead of going to Nango's
    /// dashboard blind.
    func providers() async throws -> [ProviderInfo] {
        guard let req = authorizedRequest(url: baseURL().appendingPathComponent("nango/providers")) else {
            throw NangoError.notLicensed
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NangoError.apiError(http.statusCode, msg.prefix(300).description)
        }
        struct Wrapper: Decodable { let providers: [ProviderInfo] }
        return try JSONDecoder().decode(Wrapper.self, from: data).providers
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension NangoClient: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // On macOS, the key window is fine as the anchor. If no window is
        // keyed (the menu-bar app case), fall back to a fresh ASAnchor.
        if let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            return w
        }
        return ASPresentationAnchor()
    }
}
