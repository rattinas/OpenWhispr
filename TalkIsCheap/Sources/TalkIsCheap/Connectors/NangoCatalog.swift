import Foundation
import SwiftUI

/// Published catalog of every Nango integration configured in our
/// project, plus connected-state for the current licensee. Drives the
/// Services settings tab dynamically.
@MainActor
final class NangoCatalog: ObservableObject {
    static let shared = NangoCatalog()
    private init() {}

    @Published private(set) var entries: [NangoClient.CatalogEntry] = []
    @Published private(set) var providers: [NangoClient.ProviderInfo] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    /// Fetches both the project catalog (configured integrations) and the
    /// full Nango provider list so the UI can render a "Browse more
    /// services" section with all 761 available providers.
    func refresh() async {
        isLoading = true
        loadError = nil
        async let entriesFuture = Task { try? await NangoClient.shared.catalog() }.value
        async let providersFuture = Task { try? await NangoClient.shared.providers() }.value
        let (newEntries, newProviders) = await (entriesFuture, providersFuture)

        if let list = newEntries {
            self.entries = list.sorted { lhs, rhs in
                if lhs.connected != rhs.connected { return lhs.connected && !rhs.connected }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }
        if let list = newProviders {
            self.providers = list.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }

        if newEntries == nil && newProviders == nil {
            self.loadError = "Couldn't reach TalkIsCheap Server."
        }
        isLoading = false
    }

    /// Providers that don't yet have an integration configured in the
    /// user's Nango project — candidates for the "Add more" browser.
    func unconfiguredProviders() -> [NangoClient.ProviderInfo] {
        let configuredProviders = Set(entries.map { $0.provider.lowercased() })
        return providers.filter { !configuredProviders.contains($0.name.lowercased()) }
    }

    /// Group entries by category for sectioned rendering.
    func grouped() -> [(String, [NangoClient.CatalogEntry])] {
        var buckets: [String: [NangoClient.CatalogEntry]] = [:]
        for e in entries {
            let cat = e.category ?? "other"
            buckets[cat, default: []].append(e)
        }
        let order = ["ecommerce", "marketing", "dev", "recruiting", "productivity", "other"]
        return order.compactMap { cat in
            guard let list = buckets[cat], !list.isEmpty else { return nil }
            return (cat, list)
        }
    }

    /// Find the first connected integration matching a given upstream provider.
    /// Used by the specific Connector query handlers (Stripe/Shopify/etc.)
    /// to get the connection_id they need for Nango proxy calls.
    func connectedEntry(forProvider provider: String) -> NangoClient.CatalogEntry? {
        entries.first { $0.connected && $0.provider.lowercased() == provider.lowercased() }
    }
}

// MARK: - Connector convenience: run a Nango-proxied request if the
// catalog reports this provider as connected for the licensee.

extension Connector {
    /// Makes a Nango-proxied upstream request for this connector's
    /// `nangoProvider`. Throws `ConnectorError.notConnected` if the
    /// catalog doesn't have a live connection for this provider.
    @MainActor
    func nangoProxy(
        path: String,
        method: String = "GET",
        body: Any? = nil
    ) async throws -> Data {
        guard let provider = nangoProvider else {
            throw ConnectorError.notConnected(name)
        }
        guard let entry = NangoCatalog.shared.connectedEntry(forProvider: provider),
              let connectionId = entry.connectionId
        else {
            throw ConnectorError.notConnected(name)
        }
        return try await NangoClient.shared.proxy(
            integrationKey: entry.uniqueKey,
            connectionId: connectionId,
            path: path,
            method: method,
            body: body
        )
    }

    /// True when the catalog reports a live connection for this connector's
    /// `nangoProvider`. Individual connectors can override isConnected
    /// to also count a pasted-credential state.
    @MainActor
    var isNangoConnected: Bool {
        guard let provider = nangoProvider else { return false }
        return NangoCatalog.shared.connectedEntry(forProvider: provider) != nil
    }
}

// MARK: - Category presentation helpers

enum NangoCategoryDisplay {
    static func label(_ key: String) -> String {
        switch key {
        case "ecommerce":    return "E-Commerce"
        case "marketing":    return "Marketing & Analytics"
        case "dev":          return "Development"
        case "recruiting":   return "Recruiting"
        case "productivity": return "Productivity"
        default:             return "Other"
        }
    }

    static func icon(_ key: String) -> String {
        switch key {
        case "ecommerce":    return "cart.fill"
        case "marketing":    return "chart.line.uptrend.xyaxis"
        case "dev":          return "hammer.fill"
        case "recruiting":   return "person.3.fill"
        case "productivity": return "list.bullet.rectangle"
        default:             return "square.grid.2x2"
        }
    }
}
