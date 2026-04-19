import Foundation

/// Google Ads — campaign spend & performance via Google Ads API.
///
/// Auth model: **OAuth2 + Developer Token**
/// - Developer token: issued per Google Ads Manager account. Test-level
///   tokens work immediately against test accounts; Basic / Standard
///   access requires app review by Google (2-4 weeks typically).
/// - OAuth refresh token: obtained once via the OAuth Playground or a
///   desktop flow. We let the user paste the refresh token + client ID/
///   secret for now — a full PKCE OAuth flow is a follow-up.
///
/// The API uses gRPC officially, but the REST transport works fine for
/// the read-only queries we need (searchStream / search). Calls go to
/// `googleads.googleapis.com/v17/customers/{CUSTOMER_ID}/googleAds:search`.
@MainActor
final class GoogleAdsConnector: Connector {
    static let shared = GoogleAdsConnector()
    private init() {}

    // MARK: Identity
    let id = "google_ads"
    let name = "Google Ads"
    let icon = "megaphone.fill"
    let accentColorHex = "#4285F4"

    let keywords: [String] = [
        "google ads", "adwords", "campaign", "campaigns", "kampagnen",
        "ad spend", "werbeausgaben", "cpc", "ctr", "impressions",
        "impressionen", "clicks", "klicks", "roas", "conversions",
        "anzeigen", "ads", "cost", "kosten"
    ]
    let serviceNames: [String] = ["google ads", "googleads", "adwords"]
    let category: ConnectorCategory = .marketing

    let setupGuide: [SetupStep] = [
        SetupStep(
            "1. Get a Developer Token",
            detail: "You need a Google Ads Manager (MCC) account. The developer token lives under API Center → Developer token. Test-level tokens work immediately against test accounts. For production data, apply for Basic access — approval takes 2-4 weeks.",
            actionLabel: "Open Google Ads API Center",
            actionURL: "https://ads.google.com/aw/apicenter"
        ),
        SetupStep(
            "2. Find your Customer ID",
            detail: "Top right of Google Ads UI, format: 123-456-7890. Paste it below without dashes."
        ),
        SetupStep(
            "3. Create OAuth2 credentials (one-time)",
            detail: "Cloud Console → APIs & Services → Credentials → 'Create credentials' → OAuth client ID → Application type: 'Desktop app'. Copy the Client ID + Client Secret.",
            actionLabel: "Open OAuth credentials page",
            actionURL: "https://console.cloud.google.com/apis/credentials"
        ),
        SetupStep(
            "4. Enable the Google Ads API in the project",
            actionLabel: "Enable Google Ads API",
            actionURL: "https://console.cloud.google.com/apis/library/googleads.googleapis.com"
        ),
        SetupStep(
            "5. Obtain a refresh token",
            detail: "Easiest: Google OAuth Playground. Set scope to `https://www.googleapis.com/auth/adwords`, authorize, exchange for tokens, copy the refresh_token. It never expires unless revoked.",
            actionLabel: "Open OAuth Playground",
            actionURL: "https://developers.google.com/oauthplayground/?scopes=https://www.googleapis.com/auth/adwords"
        ),
        SetupStep(
            "6. Paste everything below",
            detail: "Developer token + Customer ID + Client ID + Client Secret + Refresh Token. All five are required for the API to authenticate."
        ),
    ]

    // MARK: Credentials

    let credentialFields: [(key: String, label: String, isSecret: Bool)] = [
        (key: "developerToken", label: "Developer Token",                        isSecret: true),
        (key: "customerId",     label: "Customer ID (digits only, no dashes)",   isSecret: false),
        (key: "clientId",       label: "OAuth Client ID",                        isSecret: false),
        (key: "clientSecret",   label: "OAuth Client Secret",                    isSecret: true),
        (key: "refreshToken",   label: "OAuth Refresh Token",                    isSecret: true),
        (key: "loginCustomerId", label: "Manager (MCC) Customer ID (optional)",  isSecret: false),
    ]

    private var developerToken: String?
    private var customerId: String?
    private var clientId: String?
    private var clientSecret: String?
    private var refreshToken: String?
    private var loginCustomerId: String?

    private var cachedAccessToken: String?
    private var accessTokenExpiry: Date?

    var isConnected: Bool {
        !(developerToken ?? "").isEmpty
            && !(customerId ?? "").isEmpty
            && !(clientId ?? "").isEmpty
            && !(clientSecret ?? "").isEmpty
            && !(refreshToken ?? "").isEmpty
    }

    func connect(credentials: [String: String]) throws {
        let dev = (credentials["developerToken"] ?? "").trimmingCharacters(in: .whitespaces)
        let cust = (credentials["customerId"] ?? "")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "")
        let cid = (credentials["clientId"] ?? "").trimmingCharacters(in: .whitespaces)
        let cs  = (credentials["clientSecret"] ?? "").trimmingCharacters(in: .whitespaces)
        let rt  = (credentials["refreshToken"] ?? "").trimmingCharacters(in: .whitespaces)

        guard !dev.isEmpty else { throw ConnectorError.missingCredential("Developer Token") }
        guard !cust.isEmpty, cust.allSatisfy(\.isNumber) else {
            throw ConnectorError.missingCredential("Customer ID (digits only)")
        }
        guard !cid.isEmpty else { throw ConnectorError.missingCredential("OAuth Client ID") }
        guard !cs.isEmpty else { throw ConnectorError.missingCredential("OAuth Client Secret") }
        guard !rt.isEmpty else { throw ConnectorError.missingCredential("Refresh Token") }

        self.developerToken = dev
        self.customerId = cust
        self.clientId = cid
        self.clientSecret = cs
        self.refreshToken = rt
        let mcc = (credentials["loginCustomerId"] ?? "")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "")
        self.loginCustomerId = mcc.isEmpty ? nil : mcc
        self.cachedAccessToken = nil
        self.accessTokenExpiry = nil
    }

    func disconnect() {
        developerToken = nil
        customerId = nil
        clientId = nil
        clientSecret = nil
        refreshToken = nil
        loginCustomerId = nil
        cachedAccessToken = nil
        accessTokenExpiry = nil
    }

    // MARK: Query

    func query(intent: ConnectorIntent) async throws -> ConnectorResult {
        guard isConnected,
              let developerToken, let customerId, let refreshToken
        else { throw ConnectorError.notConnected(name) }

        let accessToken = try await fetchAccessToken()
        let start = iso(intent.timeRange.startDate)
        let end = iso(intent.timeRange.endDate)

        // GAQL — read campaign-level spend & performance for the time window.
        let gaql = """
        SELECT campaign.name, metrics.cost_micros, metrics.clicks,
               metrics.impressions, metrics.conversions, metrics.average_cpc
        FROM campaign
        WHERE segments.date BETWEEN '\(start)' AND '\(end)'
        ORDER BY metrics.cost_micros DESC
        LIMIT 25
        """

        let url = URL(string: "https://googleads.googleapis.com/v17/customers/\(customerId)/googleAds:search")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(developerToken, forHTTPHeaderField: "developer-token")
        if let loginCustomerId { req.setValue(loginCustomerId, forHTTPHeaderField: "login-customer-id") }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": gaql])
        req.timeoutInterval = 30

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "Unknown"
            throw ConnectorError.apiError("Google Ads \(http.statusCode): \(body.prefix(300))")
        }

        _ = refreshToken  // silence unused warning when the remaining body is stubbed out
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]]
        else {
            throw ConnectorError.parseError("No results field in response")
        }

        var totalCostMicros: Int64 = 0
        var totalClicks: Int64 = 0
        var totalImpressions: Int64 = 0
        var totalConversions: Double = 0
        var campaignLines: [String] = []

        for row in results {
            let campaign = (row["campaign"] as? [String: Any])?["name"] as? String ?? "?"
            let metrics = row["metrics"] as? [String: Any] ?? [:]
            let cost = Int64((metrics["costMicros"] as? String).flatMap(Int64.init) ?? 0)
            let clicks = Int64((metrics["clicks"] as? String).flatMap(Int64.init) ?? 0)
            let impr = Int64((metrics["impressions"] as? String).flatMap(Int64.init) ?? 0)
            let conv = (metrics["conversions"] as? Double) ?? Double(metrics["conversions"] as? Int ?? 0)

            totalCostMicros += cost
            totalClicks += clicks
            totalImpressions += impr
            totalConversions += conv

            if campaignLines.count < 5 {
                let spend = Double(cost) / 1_000_000.0
                campaignLines.append(String(format: "- **%@** — €%.2f · %lld clicks · %.0f conversions", campaign, spend, clicks, conv))
            }
        }

        let totalSpend = Double(totalCostMicros) / 1_000_000.0
        let ctr = totalImpressions > 0 ? Double(totalClicks) / Double(totalImpressions) * 100 : 0

        var md = "## Google Ads — \(intent.timeRange.displayName)\n\n"
        md += String(format: "**Spend:** €%.2f · **Clicks:** %lld · **Impressions:** %lld · **Conversions:** %.0f · **CTR:** %.2f%%\n\n", totalSpend, totalClicks, totalImpressions, totalConversions, ctr)
        if !campaignLines.isEmpty {
            md += "### Top campaigns by spend\n\n"
            md += campaignLines.joined(separator: "\n")
        } else {
            md += "No active campaigns in this range.\n"
        }

        return ConnectorResult(
            connectorId: id,
            connectorName: name,
            icon: icon,
            answer: md,
            rawData: root,
            timeRange: intent.timeRange,
            cachedAt: Date()
        )
    }

    // MARK: Helpers

    private func fetchAccessToken() async throws -> String {
        if let token = cachedAccessToken, let exp = accessTokenExpiry, exp > Date().addingTimeInterval(60) {
            return token
        }
        guard let clientId, let clientSecret, let refreshToken else {
            throw ConnectorError.notConnected(name)
        }

        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id=\(clientId)",
            "client_secret=\(clientSecret)",
            "refresh_token=\(refreshToken)",
            "grant_type=refresh_token",
        ].joined(separator: "&")
        req.httpBody = body.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ConnectorError.apiError("OAuth refresh failed (\(http.statusCode)): \(body.prefix(200))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int
        else {
            throw ConnectorError.parseError("Access token response")
        }

        cachedAccessToken = token
        accessTokenExpiry = Date().addingTimeInterval(Double(expiresIn))
        return token
    }

    private func iso(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
