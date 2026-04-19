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
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    /// Fetches the catalog from our backend. Safe to call repeatedly.
    func refresh() async {
        isLoading = true
        loadError = nil
        do {
            let list = try await NangoClient.shared.catalog()
            self.entries = list.sorted { lhs, rhs in
                if lhs.connected != rhs.connected { return lhs.connected && !rhs.connected }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        } catch {
            self.loadError = error.localizedDescription
        }
        isLoading = false
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
