import Foundation
import Security

/// Manages all available connectors, Keychain credential storage, and intent routing.
final class ConnectorRegistry: ObservableObject {
    static let shared = ConnectorRegistry()

    let allConnectors: [any Connector] = [
        ShopifyConnector.shared,
        StripeConnector.shared,
        GitHubConnector.shared,
        GoogleAnalyticsConnector.shared,
        GoogleAdsConnector.shared,
        MetaAdsConnector.shared,
        GmailConnector.shared,
    ]

    /// Connectors grouped by category for the settings UI.
    func connectorsByCategory() -> [(ConnectorCategory, [any Connector])] {
        var grouped: [ConnectorCategory: [any Connector]] = [:]
        for c in allConnectors {
            grouped[c.category, default: []].append(c)
        }
        // Return categories in a stable order matching the enum case order.
        return ConnectorCategory.allCases.compactMap { cat in
            guard let list = grouped[cat], !list.isEmpty else { return nil }
            return (cat, list)
        }
    }

    // 15-minute result cache: key = "connectorId:normalizedQuery"
    private var cache: [String: ConnectorResult] = [:]
    private let cacheTTL: TimeInterval = 900

    private init() {
        for connector in allConnectors {
            if let creds = loadCredentials(for: connector.id) {
                try? connector.connect(credentials: creds)
            }
        }
    }

    var connectedConnectors: [any Connector] {
        allConnectors.filter { $0.isConnected }
    }

    // MARK: - Connect / Disconnect

    func connect(connector: any Connector, credentials: [String: String]) throws {
        try connector.connect(credentials: credentials)
        try saveCredentials(credentials, for: connector.id)
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    func disconnect(connector: any Connector) {
        connector.disconnect()
        deleteCredentials(for: connector.id)
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    // MARK: - Intent Routing

    func connector(for intent: ConnectorIntent) -> (any Connector)? {
        // Explicit service name wins
        if let hint = intent.connectorHint {
            if let match = connectedConnectors.first(where: {
                $0.serviceNames.contains(hint) || $0.id == hint
            }) { return match }
        }
        // Keyword matching — most keyword hits wins
        let candidates = connectedConnectors.compactMap { c -> (connector: any Connector, hits: Int)? in
            let hits = c.keywords.filter { intent.normalized.contains($0) }.count
            return hits > 0 ? (c, hits) : nil
        }
        return candidates.max(by: { $0.hits < $1.hits })?.connector
    }

    // MARK: - Cached Query

    func query(connector: any Connector, intent: ConnectorIntent) async throws -> ConnectorResult {
        let key = "\(connector.id):\(intent.normalized)"
        if let cached = cache[key], Date().timeIntervalSince(cached.cachedAt) < cacheTTL {
            return cached
        }
        let result = try await connector.query(intent: intent)
        cache[key] = result
        return result
    }

    func clearCache() {
        cache.removeAll()
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    // MARK: - Keychain

    func saveCredentials(_ credentials: [String: String], for connectorId: String) throws {
        guard let data = try? JSONSerialization.data(withJSONObject: credentials) else { return }
        let account = "connector.\(connectorId)"
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "TalkIsCheap",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        var addQuery = deleteQuery
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            throw ConnectorError.apiError("Keychain error \(status)")
        }
    }

    func loadCredentials(for connectorId: String) -> [String: String]? {
        let account = "connector.\(connectorId)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "TalkIsCheap",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        else { return nil }
        return dict
    }

    private func deleteCredentials(for connectorId: String) {
        let account = "connector.\(connectorId)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "TalkIsCheap",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
