import Foundation

// MARK: - ShopifyConnector

final class ShopifyConnector: Connector {

    // MARK: Shared instance

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
    let nangoProvider: String? = "shopify"
    let pipedreamAppSlug: String? = "shopify"

    let setupGuide: [SetupStep] = [
        SetupStep(
            "1. Open your store's Custom Apps page",
            detail: "Replace YOURSTORE with your store handle (the part before .myshopify.com). If you're not sure, open admin.shopify.com first — the URL will show it.",
            actionLabel: "Open admin.shopify.com",
            actionURL: "https://admin.shopify.com"
        ),
        SetupStep(
            "2. Settings → Apps and sales channels → Develop apps",
            detail: "If 'Develop apps' is greyed out, click 'Allow custom app development' and confirm — only needs to happen once per store."
        ),
        SetupStep(
            "3. Create an app",
            detail: "Name it something like \"TalkIsCheap Read-only\". The name only shows up in the store admin, not publicly."
        ),
        SetupStep(
            "4. Configure Admin API scopes",
            detail: "Tick the READ permissions for what you want to query. Minimum recommended:",
            copyable: "read_orders\nread_products\nread_customers\nread_inventory"
        ),
        SetupStep(
            "5. Install app → Reveal token once",
            detail: "After clicking 'Install app' the Admin API access token appears. Shopify only shows it ONCE — copy it immediately. It starts with shpat_."
        ),
        SetupStep(
            "6. Paste token + shop domain below",
            detail: "Shop domain is the full mystore.myshopify.com form. Token is the shpat_... string."
        ),
    ]

    // MARK: Credential fields

    let credentialFields: [(key: String, label: String, isSecret: Bool)] = [
        (key: "shopDomain",    label: "Shop Domain (e.g. mystore.myshopify.com)", isSecret: false),
        (key: "accessToken",   label: "Admin API Access Token",                   isSecret: true)
    ]

    // MARK: Private state

    private var shopDomain: String?
    private var accessToken: String?

    // MARK: isConnected

    @MainActor
    var isConnected: Bool {
        if isPipedreamConnected { return true }
        if isNangoConnected { return true }
        guard let domain = shopDomain, let token = accessToken else { return false }
        return !domain.isEmpty && !token.isEmpty
    }

    // MARK: connect / disconnect

    func connect(credentials: [String: String]) throws {
        var domain = (credentials["shopDomain"] ?? "").trimmingCharacters(in: .whitespaces)
        let token  = (credentials["accessToken"] ?? "").trimmingCharacters(in: .whitespaces)

        guard !domain.isEmpty else { throw ConnectorError.missingCredential("shopDomain") }
        guard !token.isEmpty  else { throw ConnectorError.missingCredential("accessToken") }

        // Strip trailing slashes
        while domain.hasSuffix("/") { domain.removeLast() }

        shopDomain   = domain
        accessToken  = token
    }

    func disconnect() {
        shopDomain  = nil
        accessToken = nil
    }

    // MARK: query

    @MainActor
    func query(intent: ConnectorIntent) async throws -> ConnectorResult {
        let startISO = isoString(from: intent.timeRange.startDate)
        let endISO   = isoString(from: intent.timeRange.endDate)
        let path = "/admin/api/2024-01/orders.json"
            + "?created_at_min=\(startISO)"
            + "&created_at_max=\(endISO)"
            + "&status=any"
            + "&limit=250"
            + "&fields=id,total_price,financial_status,currency,created_at,line_items"

        let data: Data
        if isPipedreamConnected {
            // Pipedream's Shopify proxy resolves the shop domain from the
            // connected account automatically — the host in the URL is
            // substituted server-side.
            data = try await pipedreamProxy(url: "https://{shop}.myshopify.com\(path)")
        } else if isNangoConnected {
            data = try await nangoProxy(path: path)
        } else {
            guard let domain = shopDomain, !domain.isEmpty else {
                throw ConnectorError.notConnected(name)
            }
            data = try await apiGet(url: "https://\(domain)\(path)")
        }

        // MARK: Parse

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let orders = json["orders"] as? [[String: Any]]
        else {
            throw ConnectorError.parseError("Unexpected orders response shape")
        }

        // Revenue & order counts
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

        let orderCount = orders.count

        // Top products by quantity sold
        var productQuantities: [String: Int] = [:]
        for order in orders {
            guard let lineItems = order["line_items"] as? [[String: Any]] else { continue }
            for item in lineItems {
                let title    = item["name"] as? String ?? item["title"] as? String ?? "Unknown"
                let quantity = item["quantity"] as? Int ?? 0
                productQuantities[title, default: 0] += quantity
            }
        }

        let top5 = productQuantities
            .sorted { $0.value > $1.value }
            .prefix(5)

        // Format currency
        let currencyFormatter = NumberFormatter()
        currencyFormatter.numberStyle = .currency
        currencyFormatter.currencyCode = detectedCurrency
        let revenueFormatted = currencyFormatter.string(from: NSNumber(value: totalRevenue))
            ?? "\(detectedCurrency) \(totalRevenue)"

        // Build Markdown answer
        let heading = intent.timeRange.displayName.prefix(1).uppercased()
            + intent.timeRange.displayName.dropFirst()

        var lines: [String] = [
            "## Shopify \u{2014} \(heading)",
            "",
            "**Revenue:** \(revenueFormatted)",
            "**Orders:** \(orderCount) total, \(paidCount) paid",
            "",
            "**Top Products:**"
        ]

        if top5.isEmpty {
            lines.append("- No products in this period")
        } else {
            for (title, qty) in top5 {
                lines.append("- \(title): \(qty) sold")
            }
        }

        let answer = lines.joined(separator: "\n")

        let rawData: [String: Any] = [
            "orders": orders,
            "totalRevenue": totalRevenue,
            "orderCount": orderCount,
            "paidCount": paidCount,
            "currency": detectedCurrency
        ]

        return ConnectorResult(
            connectorId:   id,
            connectorName: name,
            icon:          icon,
            answer:        answer,
            rawData:       rawData,
            timeRange:     intent.timeRange,
            cachedAt:      Date()
        )
    }

    // MARK: Private helpers

    private func apiGet(url: String) async throws -> Data {
        guard let token = accessToken else {
            throw ConnectorError.notConnected(name)
        }
        guard let requestURL = URL(string: url) else {
            throw ConnectorError.apiError("Invalid URL: \(url)")
        }

        var request = URLRequest(url: requestURL, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-Shopify-Access-Token")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError.apiError("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "(empty)"
            throw ConnectorError.apiError("Shopify API returned \(http.statusCode): \(body)")
        }

        return data
    }

    private func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
