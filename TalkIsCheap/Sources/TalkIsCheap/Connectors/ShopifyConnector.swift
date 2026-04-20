import Foundation

/// Shopify — connected via our own backend OAuth (NOT Pipedream).
///
/// Why not Pipedream: Shopify's Partner App architecture forbids sharing a
/// single OAuth app across merchants — every install happens against a
/// Partner-App-owned client_id that routes to our own callback URL. So we
/// run the install flow in the TalkIsCheap backend (`/api/shopify/oauth/*`)
/// and persist one access token per (license, shop) pair.
///
/// The Mac app talks only to `ShopifyNativeClient`, never to Shopify directly.
@MainActor
final class ShopifyConnector: Connector {

    static let shared = ShopifyConnector()
    private init() {}

    // MARK: Connector identity

    let id = "shopify"
    let name = "Shopify"
    let icon = "cart.fill"
    let accentColorHex = "#95BF47"

    let keywords: [String] = [
        "revenue", "umsatz", "sales", "orders", "bestellungen",
        "products", "produkte", "customers", "kunden",
        "shop", "store", "verkauf", "einnahmen", "conversion", "shopify"
    ]

    let serviceNames: [String] = ["shopify"]
    let category: ConnectorCategory = .ecommerce

    // Explicitly no Pipedream integration — handled by ShopifyNativeClient.
    let pipedreamAppSlug: String? = nil
    let nangoProvider: String? = nil

    let setupGuide: [SetupStep] = [
        SetupStep(
            "Open your Shopify Admin in this browser",
            detail: "Make sure you're already signed into the store you want to connect — the install flow uses your existing session.",
            actionLabel: "Open admin.shopify.com",
            actionURL: "https://admin.shopify.com"
        ),
        SetupStep(
            "Enter the store handle in TalkIsCheap",
            detail: "Just the part before .myshopify.com (e.g. \"mystore\"). We handle the rest — no tokens, no Partner account needed.",
        ),
        SetupStep(
            "Click Install on the Shopify page that opens",
            detail: "Shopify will ask you to approve read access to orders, products, customers, and inventory. After approval you can close the tab — TalkIsCheap picks up the connection automatically."
        ),
    ]

    // No manual credential fields — OAuth handles everything.
    let credentialFields: [(key: String, label: String, isSecret: Bool)] = []

    // MARK: isConnected — true if at least one store is linked

    var isConnected: Bool {
        !ShopifyNativeClient.shared.connections.isEmpty
    }

    /// Legacy stub; OAuth is started via `ShopifyNativeClient.startInstallFlow`.
    /// Keeping `connect(credentials:)` as a no-op so the `Connector` protocol is satisfied.
    func connect(credentials: [String: String]) throws {
        // no-op — see ShopifyNativeClient.startInstallFlow(forShop:)
    }

    func disconnect() {
        // Cooperative disconnect removes all stores for this license.
        let client = ShopifyNativeClient.shared
        let domains = client.connections.map(\.shopDomain)
        Task { @MainActor in
            for d in domains {
                try? await client.disconnect(shop: d)
            }
        }
    }

    // MARK: query

    func query(intent: ConnectorIntent) async throws -> ConnectorResult {
        let client = ShopifyNativeClient.shared
        // Ensure we know which stores are connected (first call after launch).
        if client.connections.isEmpty {
            await client.refresh()
        }
        guard let primary = pickShop(for: intent, among: client.connections) else {
            throw ConnectorError.notConnected(name)
        }

        let startISO = isoString(from: intent.timeRange.startDate)
        let endISO   = isoString(from: intent.timeRange.endDate)
        let path = "/orders.json"
            + "?created_at_min=\(startISO)"
            + "&created_at_max=\(endISO)"
            + "&status=any"
            + "&limit=250"
            + "&fields=id,total_price,financial_status,currency,created_at,line_items"

        let data = try await client.proxy(shop: primary.shopDomain, path: path)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let orders = json["orders"] as? [[String: Any]]
        else {
            throw ConnectorError.parseError("Unexpected orders response shape")
        }

        // --- Parse & summarise -------------------------------------------------

        var totalRevenue: Double = 0
        var paidCount = 0
        var detectedCurrency = "USD"
        var currencyDetected = false

        for order in orders {
            let status = order["financial_status"] as? String ?? ""
            if status == "paid" {
                if let priceStr = order["total_price"] as? String,
                   let price = Double(priceStr) {
                    totalRevenue += price
                }
                paidCount += 1
                if !currencyDetected, let currency = order["currency"] as? String, !currency.isEmpty {
                    detectedCurrency = currency
                    currencyDetected = true
                }
            }
        }

        // Top products by quantity.
        var productQuantities: [String: Int] = [:]
        for order in orders {
            guard let lineItems = order["line_items"] as? [[String: Any]] else { continue }
            for item in lineItems {
                let title    = item["name"] as? String ?? item["title"] as? String ?? "Unknown"
                let quantity = item["quantity"] as? Int ?? 0
                productQuantities[title, default: 0] += quantity
            }
        }
        let top5 = productQuantities.sorted { $0.value > $1.value }.prefix(5)

        let currencyFormatter = NumberFormatter()
        currencyFormatter.numberStyle = .currency
        currencyFormatter.currencyCode = detectedCurrency
        let revenueFormatted = currencyFormatter.string(from: NSNumber(value: totalRevenue))
            ?? "\(detectedCurrency) \(totalRevenue)"

        let heading = intent.timeRange.displayName.prefix(1).uppercased()
            + intent.timeRange.displayName.dropFirst()

        // Include the shop handle in the header so multi-store users know
        // which store the numbers are for.
        var lines: [String] = [
            "## 🛒 Shopify · \(primary.shopHandle) — \(heading)",
            "",
            "**Revenue:** \(revenueFormatted)",
            "**Orders:** \(orders.count) total, \(paidCount) paid",
            "",
            "**Top Products:**",
        ]
        if top5.isEmpty {
            lines.append("- No products in this period")
        } else {
            for (title, qty) in top5 {
                lines.append("- \(title): \(qty) sold")
            }
        }

        // If the user has multiple connected stores, hint at the syntax for
        // targeting a specific one in the next query.
        if client.connections.count > 1 {
            lines.append("")
            let others = client.connections
                .filter { $0.shopDomain != primary.shopDomain }
                .map(\.shopHandle)
                .joined(separator: ", ")
            lines.append("_Tip: add the store handle to target another store (e.g. `\(others)`)._")
        }

        return ConnectorResult(
            connectorId: id,
            connectorName: name,
            icon: icon,
            answer: lines.joined(separator: "\n"),
            rawData: [
                "orders": orders,
                "totalRevenue": totalRevenue,
                "orderCount": orders.count,
                "paidCount": paidCount,
                "currency": detectedCurrency,
                "shop": primary.shopDomain,
            ],
            timeRange: intent.timeRange,
            cachedAt: Date()
        )
    }

    // MARK: - Disambiguation

    /// Picks which of the connected stores to query. If the user said a
    /// specific handle in their query ("umsatz von noser-fashion"), prefer
    /// that; otherwise fall back to the most recently used store, or the
    /// first one.
    private func pickShop(
        for intent: ConnectorIntent,
        among connections: [ShopifyNativeClient.Connection]
    ) -> ShopifyNativeClient.Connection? {
        if connections.isEmpty { return nil }
        let q = intent.normalized
        if let named = connections.first(where: {
            q.contains($0.shopHandle.lowercased())
            || q.contains($0.shopDomain.lowercased())
        }) {
            return named
        }
        // Most recently used first.
        return connections.sorted { (a, b) in
            (a.lastUsedAt ?? "") > (b.lastUsedAt ?? "")
        }.first ?? connections.first
    }

    // MARK: - Helpers

    private func isoString(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
