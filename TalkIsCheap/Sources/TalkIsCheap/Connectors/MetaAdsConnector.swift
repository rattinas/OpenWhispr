import Foundation

/// Meta Ads (Facebook / Instagram) — ad-account metrics via Marketing API.
///
/// Auth model: **System User Access Token** (long-lived, non-expiring).
/// The user creates a System User in Meta Business Manager, assigns the ad
/// account with `ads_read` permission, generates a token bound to a Meta
/// App, and pastes it. Unlike regular user tokens (which expire after
/// 60 days), system user tokens are valid until revoked — perfect for a
/// desktop tool that shouldn't need OAuth renewal loops.
///
/// API docs: https://developers.facebook.com/docs/marketing-api/insights
@MainActor
final class MetaAdsConnector: Connector {
    static let shared = MetaAdsConnector()
    private init() {}

    // MARK: Identity
    let id = "meta_ads"
    let name = "Meta Ads"
    let icon = "f.cursive.circle.fill"
    let accentColorHex = "#1877F2"

    let keywords: [String] = [
        "meta ads", "facebook ads", "instagram ads", "facebook", "fb",
        "meta", "insta", "instagram", "kampagne", "kampagnen",
        "campaign", "campaigns", "ad spend", "werbeausgaben",
        "reach", "reichweite", "impressions", "cpm", "ctr", "roas"
    ]
    let serviceNames: [String] = ["meta ads", "meta", "facebook ads", "facebook", "instagram ads", "fb ads"]
    let category: ConnectorCategory = .marketing

    let setupGuide: [SetupStep] = [
        SetupStep(
            "1. Create a Meta App (skip if you already have one)",
            detail: "App Type: 'Business'. The app just needs to exist — it's the container that owns the System User token.",
            actionLabel: "Open Meta for Developers",
            actionURL: "https://developers.facebook.com/apps/"
        ),
        SetupStep(
            "2. Open Business Manager → System Users",
            detail: "In Business Settings (gear icon): Users → System Users → Add. Pick 'Admin' role. Name it 'TalkIsCheap'.",
            actionLabel: "Open Business Settings — System Users",
            actionURL: "https://business.facebook.com/settings/system-users"
        ),
        SetupStep(
            "3. Assign your ad account",
            detail: "With the system user selected → 'Add Assets' → Ad Accounts → pick your account → toggle 'Manage ad account' OFF and 'View performance' ON (or both if you also want to pause campaigns later)."
        ),
        SetupStep(
            "4. Generate a long-lived token",
            detail: "System user screen → 'Generate New Token' → pick your Meta app → select scope **ads_read** (and `read_insights` if you want breakdowns). Never expires unless revoked. Copy it immediately — Meta only shows it once."
        ),
        SetupStep(
            "5. Find your Ad Account ID",
            detail: "Ads Manager → top-left account dropdown. Format: `act_1234567890` (keep the `act_` prefix). Paste the full string below.",
            actionLabel: "Open Ads Manager",
            actionURL: "https://adsmanager.facebook.com"
        ),
        SetupStep(
            "6. Paste Access Token + Ad Account ID below"
        ),
    ]

    let credentialFields: [(key: String, label: String, isSecret: Bool)] = [
        (key: "accessToken", label: "System User Access Token",            isSecret: true),
        (key: "adAccountId", label: "Ad Account ID (act_1234567890 form)", isSecret: false),
    ]

    private var accessToken: String?
    private var adAccountId: String?

    var isConnected: Bool {
        !(accessToken ?? "").isEmpty && !(adAccountId ?? "").isEmpty
    }

    func connect(credentials: [String: String]) throws {
        let tok = (credentials["accessToken"] ?? "").trimmingCharacters(in: .whitespaces)
        var id = (credentials["adAccountId"] ?? "").trimmingCharacters(in: .whitespaces)

        guard !tok.isEmpty else { throw ConnectorError.missingCredential("Access Token") }
        guard !id.isEmpty else { throw ConnectorError.missingCredential("Ad Account ID") }
        // Auto-prepend act_ if the user pasted just the digits
        if !id.hasPrefix("act_") { id = "act_" + id }

        self.accessToken = tok
        self.adAccountId = id
    }

    func disconnect() {
        accessToken = nil
        adAccountId = nil
    }

    // MARK: Query

    func query(intent: ConnectorIntent) async throws -> ConnectorResult {
        guard isConnected, let accessToken, let adAccountId else {
            throw ConnectorError.notConnected(name)
        }

        let since = iso(intent.timeRange.startDate)
        let until = iso(intent.timeRange.endDate)
        // Fields cover the most common questions ("wie viel haben wir
        // ausgegeben", "wie hoch ist der ROAS"). Breakdowns intentionally
        // omitted for now — keep the response small for voice read-out.
        let fields = "spend,impressions,clicks,cpm,cpc,ctr,reach,frequency,conversions,purchase_roas"
        let timeRange = "{\"since\":\"\(since)\",\"until\":\"\(until)\"}"

        var components = URLComponents(string: "https://graph.facebook.com/v20.0/\(adAccountId)/insights")!
        components.queryItems = [
            URLQueryItem(name: "fields", value: fields),
            URLQueryItem(name: "time_range", value: timeRange),
            URLQueryItem(name: "level", value: "account"),
            URLQueryItem(name: "access_token", value: accessToken),
        ]

        var req = URLRequest(url: components.url!)
        req.timeoutInterval = 20

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw ConnectorError.apiError("Meta Ads: \(message)")
            }
            throw ConnectorError.apiError("Meta Ads: HTTP \(http.statusCode)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let insights = json["data"] as? [[String: Any]]
        else {
            throw ConnectorError.parseError("Missing 'data' in Meta response")
        }

        guard let row = insights.first else {
            return ConnectorResult(
                connectorId: id,
                connectorName: name,
                icon: icon,
                answer: "## Meta Ads — \(intent.timeRange.displayName)\n\nNo ad activity in this range.",
                rawData: json,
                timeRange: intent.timeRange,
                cachedAt: Date()
            )
        }

        func num(_ key: String) -> Double {
            if let d = row[key] as? Double { return d }
            if let s = row[key] as? String, let d = Double(s) { return d }
            if let i = row[key] as? Int { return Double(i) }
            return 0
        }
        let spend = num("spend")
        let impressions = num("impressions")
        let clicks = num("clicks")
        let cpm = num("cpm")
        let cpc = num("cpc")
        let ctr = num("ctr")
        let reach = num("reach")

        // ROAS is returned as an array of {action_type, value}
        var roas: Double = 0
        if let roasArr = row["purchase_roas"] as? [[String: Any]],
           let first = roasArr.first,
           let val = first["value"] as? String,
           let d = Double(val) {
            roas = d
        }

        var md = "## Meta Ads — \(intent.timeRange.displayName)\n\n"
        md += String(format: "**Spend:** €%.2f · **Impressions:** %.0f · **Reach:** %.0f · **Clicks:** %.0f\n\n", spend, impressions, reach, clicks)
        md += String(format: "**CTR:** %.2f%% · **CPM:** €%.2f · **CPC:** €%.2f", ctr, cpm, cpc)
        if roas > 0 { md += String(format: " · **ROAS:** %.2fx", roas) }

        return ConnectorResult(
            connectorId: id,
            connectorName: name,
            icon: icon,
            answer: md,
            rawData: json,
            timeRange: intent.timeRange,
            cachedAt: Date()
        )
    }

    private func iso(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
