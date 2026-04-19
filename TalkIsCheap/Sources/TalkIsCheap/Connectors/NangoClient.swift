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
        guard let auth = authHeader() else { throw NangoError.notLicensed }
        var req = URLRequest(url: baseURL().appendingPathComponent("nango/session"))
        req.httpMethod = "POST"
        req.setValue(auth, forHTTPHeaderField: "Authorization")
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
        guard let auth = authHeader() else { throw NangoError.notLicensed }
        var comps = URLComponents(url: baseURL().appendingPathComponent("nango/connection"), resolvingAgainstBaseURL: false)!
        if let key = integrationKey {
            comps.queryItems = [URLQueryItem(name: "integrationKey", value: key)]
        }
        var req = URLRequest(url: comps.url!)
        req.setValue(auth, forHTTPHeaderField: "Authorization")
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
        guard let auth = authHeader() else { throw NangoError.notLicensed }
        var req = URLRequest(url: baseURL().appendingPathComponent("nango/connection"))
        req.httpMethod = "DELETE"
        req.setValue(auth, forHTTPHeaderField: "Authorization")
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
        guard let auth = authHeader() else { throw NangoError.notLicensed }
        var req = URLRequest(url: baseURL().appendingPathComponent("nango/proxy"))
        req.httpMethod = method.uppercased() == "GET" ? "GET" : "POST"
        req.setValue(auth, forHTTPHeaderField: "Authorization")
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
