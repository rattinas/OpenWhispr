import Foundation
import AppKit

/// Client for the TalkIsCheap backend's own Shopify OAuth endpoints.
///
/// We don't use Pipedream for Shopify — Shopify's Partner platform doesn't
/// allow shared OAuth apps across merchants, so we run the install flow
/// ourselves. The merchant's access_token lives in the backend DB keyed by
/// (license_id, shop_domain); the Mac app never sees it.
///
/// Endpoints this client calls:
///   POST   /api/shopify/oauth/start         → { authUrl, shopDomain }
///   GET    /api/shopify/connections         → { connections: [...] }
///   DELETE /api/shopify/connections?shop=X  → { ok: true }
///   POST   /api/shopify/proxy               → raw Shopify Admin API response
@MainActor
final class ShopifyNativeClient: ObservableObject {
    static let shared = ShopifyNativeClient()
    private init() {}

    private static let baseURL = "https://talkischeap.app/api/shopify"

    // MARK: - Public model

    struct Connection: Identifiable, Equatable {
        let id: Int
        let shopDomain: String
        let shopHandle: String
        let scopes: String?
        let installedAt: String?
        let lastUsedAt: String?
    }

    // MARK: - Observable state

    /// Locally cached list of connected shops. Populated by `refresh()`.
    /// UI observers (ConnectedServicesView) re-render when this changes.
    @Published private(set) var connections: [Connection] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshError: String?

    // MARK: - Auth header

    private static func addAuthHeaders(to request: inout URLRequest) {
        let settings = AppSettings.shared
        request.setValue("Bearer \(settings.activationToken)", forHTTPHeaderField: "Authorization")
        request.setValue(LicenseManager.hardwareUUID(), forHTTPHeaderField: "X-Hardware-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
    }

    // MARK: - OAuth start → open browser

    /// Kicks off the install flow for the given shop handle. Asks our backend
    /// to produce a signed `authUrl`, then opens it in the default browser.
    /// Throws if the backend rejects the request.
    @discardableResult
    func startInstallFlow(forShop handle: String) async throws -> URL {
        guard let url = URL(string: "\(Self.baseURL)/oauth/start") else {
            throw ConnectorError.apiError("Invalid URL for Shopify install start")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.addAuthHeaders(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["shop": handle])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError.apiError("No HTTP response from /api/shopify/oauth/start")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard http.statusCode == 200 else {
            let msg = json["error"] as? String ?? "HTTP \(http.statusCode)"
            throw ConnectorError.apiError("Shopify install start failed: \(msg)")
        }
        guard let authUrlStr = json["authUrl"] as? String,
              let authUrl = URL(string: authUrlStr) else {
            throw ConnectorError.apiError("Backend didn't return an authUrl")
        }

        // Open in system browser so the merchant can sign into their store.
        // ASWebAuthenticationSession would give cookie-isolation — we don't
        // want that: the merchant needs their existing store login cookies.
        NSWorkspace.shared.open(authUrl)
        return authUrl
    }

    // MARK: - Refresh list of connected shops

    /// Re-fetches the list of connected shops from our backend. Idempotent.
    func refresh() async {
        isRefreshing = true
        lastRefreshError = nil
        defer { isRefreshing = false }

        guard let url = URL(string: "\(Self.baseURL)/connections") else {
            lastRefreshError = "Bad URL"
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        Self.addAuthHeaders(to: &request)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastRefreshError = "No HTTP response"
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard http.statusCode == 200 else {
                lastRefreshError = (json["error"] as? String) ?? "HTTP \(http.statusCode)"
                return
            }
            let rawArr = (json["connections"] as? [[String: Any]]) ?? []
            connections = rawArr.compactMap { item -> Connection? in
                guard let id = item["id"] as? Int,
                      let shopDomain = item["shopDomain"] as? String,
                      let shopHandle = item["shopHandle"] as? String
                else { return nil }
                return Connection(
                    id: id,
                    shopDomain: shopDomain,
                    shopHandle: shopHandle,
                    scopes: item["scopes"] as? String,
                    installedAt: item["installedAt"] as? String,
                    lastUsedAt: item["lastUsedAt"] as? String
                )
            }
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    // MARK: - Disconnect

    func disconnect(shop shopDomain: String) async throws {
        var comps = URLComponents(string: "\(Self.baseURL)/connections")!
        comps.queryItems = [URLQueryItem(name: "shop", value: shopDomain)]
        guard let url = comps.url else {
            throw ConnectorError.apiError("Bad URL for Shopify disconnect")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "DELETE"
        Self.addAuthHeaders(to: &request)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw ConnectorError.apiError("Disconnect failed: \(msg)")
        }
        // Refresh so the UI reflects the removal.
        await refresh()
    }

    // MARK: - Admin API proxy

    /// Forwards an Admin API call through our backend. The backend attaches
    /// the stored access token for `shop`, so the Mac app never sees it.
    ///
    /// `path` is the Admin API path *without* host, e.g. `/orders.json?limit=10`
    /// or `orders.json`. The backend normalises it.
    func proxy(
        shop shopDomain: String,
        path: String,
        method: String = "GET",
        body: Any? = nil,
        apiVersion: String = "2024-10"
    ) async throws -> Data {
        guard let url = URL(string: "\(Self.baseURL)/proxy") else {
            throw ConnectorError.apiError("Bad URL for Shopify proxy")
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.addAuthHeaders(to: &request)

        var payload: [String: Any] = [
            "shop": shopDomain,
            "path": path,
            "method": method,
            "apiVersion": apiVersion,
        ]
        if let body { payload["body"] = body }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError.apiError("No HTTP response from /api/shopify/proxy")
        }

        // Pass Shopify status codes through — a 404 on the store's API is
        // different from a 404 on our own endpoint.
        guard (200..<400).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let msg = (json["error"] as? String)
                ?? (json["errors"] as? String)
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw ConnectorError.apiError("Shopify API \(http.statusCode): \(msg)")
        }
        return data
    }
}
