import Foundation

final class StripeConnector: Connector {

    // MARK: - Singleton

    static let shared = StripeConnector()
    private init() {}

    // MARK: - Connector Identity

    let id = "stripe"
    let name = "Stripe"
    let icon = "creditcard.fill"
    let accentColorHex = "#635BFF"

    let keywords: [String] = [
        "stripe", "payments", "zahlungen", "einnahmen", "revenue",
        "charges", "subscribers", "abonnenten", "subscriptions",
        "abonnements", "balance", "guthaben", "mrr", "arr",
        "customers", "kunden", "refunds", "ruckerstattungen", "umsatz"
    ]

    let serviceNames: [String] = ["stripe"]

    let credentialFields: [(key: String, label: String, isSecret: Bool)] = [
        (key: "secretKey", label: "Secret Key (sk_live_... or sk_test_...)", isSecret: true)
    ]

    // MARK: - Stored Credentials

    private var secretKey: String?

    var isConnected: Bool {
        guard let key = secretKey else { return false }
        return !key.isEmpty
    }

    // MARK: - Connect / Disconnect

    func connect(credentials: [String: String]) throws {
        guard let key = credentials["secretKey"], !key.isEmpty else {
            throw ConnectorError.missingCredential("secretKey")
        }
        guard key.hasPrefix("sk_") else {
            throw ConnectorError.apiError("Stripe secret key must start with \"sk_\"")
        }
        secretKey = key
    }

    func disconnect() {
        secretKey = nil
    }

    // MARK: - Query

    func query(intent: ConnectorIntent) async throws -> ConnectorResult {
        guard let key = secretKey, !key.isEmpty else {
            throw ConnectorError.notConnected(name)
        }

        let start = Int(intent.timeRange.startDate.timeIntervalSince1970)
        let end   = Int(intent.timeRange.endDate.timeIntervalSince1970)

        // Fetch balance and charges concurrently
        async let balanceData = apiGet(
            url: "https://api.stripe.com/v1/balance",
            key: key
        )
        async let chargesData = apiGet(
            url: "https://api.stripe.com/v1/charges?created[gte]=\(start)&created[lte]=\(end)&limit=100",
            key: key
        )

        let (balanceJSON, chargesJSON) = try await (balanceData, chargesData)

        // Parse balance
        guard
            let balanceObj = try? JSONSerialization.jsonObject(with: balanceJSON) as? [String: Any],
            let available = balanceObj["available"] as? [[String: Any]],
            let firstAvailable = available.first,
            let balanceCents = firstAvailable["amount"] as? Int,
            let balanceCurrency = firstAvailable["currency"] as? String
        else {
            throw ConnectorError.parseError("Could not read balance from Stripe response")
        }

        // Parse charges
        guard
            let chargesObj = try? JSONSerialization.jsonObject(with: chargesJSON) as? [String: Any],
            let chargeList = chargesObj["data"] as? [[String: Any]]
        else {
            throw ConnectorError.parseError("Could not read charges from Stripe response")
        }

        let paidCharges = chargeList.filter { charge in
            let paid     = charge["paid"]     as? Bool ?? false
            let refunded = charge["refunded"] as? Bool ?? false
            return paid && !refunded
        }

        let revenueAmounts = paidCharges.compactMap { $0["amount"] as? Int }
        let totalRevenueCents = revenueAmounts.reduce(0, +)
        let paidCount = paidCharges.count

        // Derive the charge currency from charges, fall back to balance currency
        let chargeCurrency: String = (paidCharges.first?["currency"] as? String) ?? balanceCurrency

        let avgCents = paidCount > 0 ? totalRevenueCents / paidCount : 0

        // Build Markdown answer
        let heading = intent.timeRange.displayName.prefix(1).uppercased()
                    + intent.timeRange.displayName.dropFirst()

        let revenueFormatted = formatCents(totalRevenueCents, currency: chargeCurrency)
        let balanceFormatted = formatCents(balanceCents,      currency: balanceCurrency)
        let avgFormatted     = formatCents(avgCents,          currency: chargeCurrency)

        let answer = """
        ## Stripe — \(heading)

        **Revenue:** \(revenueFormatted) (\(paidCount) charges)
        **Current Balance:** \(balanceFormatted)
        **Avg. Charge:** \(avgFormatted)
        """

        let rawData: [String: Any] = [
            "balance": balanceObj,
            "charges": chargesObj
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

    // MARK: - Helpers

    /// Format an amount in minor currency units (cents) using NumberFormatter.
    private func formatCents(_ cents: Int, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.uppercased()
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2

        let amount = Double(cents) / 100.0
        return formatter.string(from: NSNumber(value: amount)) ?? "\(currency.uppercased()) \(String(format: "%.2f", amount))"
    }

    /// Perform an authenticated GET against the Stripe API.
    private func apiGet(url urlString: String, key: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw ConnectorError.apiError("Invalid URL: \(urlString)")
        }

        let credentials = "\(key):"
        guard let credentialData = credentials.data(using: .utf8) else {
            throw ConnectorError.apiError("Could not encode API key")
        }
        let base64Credentials = credentialData.base64EncodedString()

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 {
                throw ConnectorError.apiError("Invalid Stripe API key")
            }
            if !(200..<300).contains(httpResponse.statusCode) {
                // Try to extract a human-readable error message from the response body
                if let errorObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorDict = errorObj["error"] as? [String: Any],
                   let message = errorDict["message"] as? String {
                    throw ConnectorError.apiError(message)
                }
                throw ConnectorError.apiError("Stripe API returned HTTP \(httpResponse.statusCode)")
            }
        }

        return data
    }
}
