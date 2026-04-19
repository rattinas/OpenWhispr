import Foundation
import Security

// MARK: - GoogleAnalyticsConnector

final class GoogleAnalyticsConnector: Connector {

    // MARK: Shared instance

    static let shared = GoogleAnalyticsConnector()
    private init() {}

    // MARK: Connector identity

    let id = "ga4"
    let name = "Google Analytics"
    let icon = "chart.bar.fill"
    let accentColorHex = "#F9AB00"

    let keywords: [String] = [
        "analytics", "google analytics", "ga4",
        "sessions", "users", "seitenaufrufe", "pageviews",
        "traffic", "besucher", "visitors",
        "konversionen", "conversions", "bounce rate", "absprungrate", "seiten"
    ]

    let serviceNames: [String] = ["google analytics", "analytics", "ga4"]
    let category: ConnectorCategory = .marketing

    let setupGuide: [SetupStep] = [
        SetupStep(
            "1. Find your GA4 Property ID",
            detail: "Open your GA4 property → Admin (gear icon, bottom left) → Property settings → copy the Property ID (a number like 123456789). This is NOT the same as the \"G-XXXXX\" measurement ID.",
            actionLabel: "Open Google Analytics",
            actionURL: "https://analytics.google.com/analytics/web/"
        ),
        SetupStep(
            "2. Create a Google Cloud project (skip if you have one)",
            detail: "Any project works. The service account you'll create lives inside it. Naming suggestion: \"TalkIsCheap\".",
            actionLabel: "Open Google Cloud Console",
            actionURL: "https://console.cloud.google.com/projectcreate"
        ),
        SetupStep(
            "3. Enable the Analytics Data API",
            detail: "In the Cloud project, the Data API must be enabled before calls succeed.",
            actionLabel: "Enable Analytics Data API",
            actionURL: "https://console.cloud.google.com/apis/library/analyticsdata.googleapis.com"
        ),
        SetupStep(
            "4. Create a Service Account",
            detail: "IAM & Admin → Service Accounts → 'Create service account'. Name: \"TalkIsCheap GA4 Reader\". Skip the optional \"Grant access to this project\" step — GA4 access is granted separately.",
            actionLabel: "Open Service Accounts",
            actionURL: "https://console.cloud.google.com/iam-admin/serviceaccounts"
        ),
        SetupStep(
            "5. Generate a JSON key",
            detail: "Click the new service account → Keys tab → 'Add key' → Create new key → JSON → Create. A .json file downloads. Copy the ENTIRE file contents to paste below."
        ),
        SetupStep(
            "6. Grant the service account access to your GA4 property",
            detail: "Back in Google Analytics: Admin → Property access management → '+' → add the service account email (looks like name@project.iam.gserviceaccount.com) with the 'Viewer' role."
        ),
        SetupStep(
            "7. Paste Property ID + full service account JSON below",
            detail: "Both values stay in your Mac's Keychain — they never leave your device except for direct API calls to Google."
        ),
    ]

    // MARK: Credential fields

    let credentialFields: [(key: String, label: String, isSecret: Bool)] = [
        (key: "propertyId",        label: "GA4 Property ID (e.g. 123456789)",       isSecret: false),
        (key: "serviceAccountJson", label: "Service Account JSON (paste entire JSON)", isSecret: true)
    ]

    // MARK: Private state

    private var propertyId: String?
    private var serviceAccountJson: String?
    private var cachedAccessToken: String?
    private var tokenExpiry: Date?

    // MARK: isConnected

    var isConnected: Bool {
        guard let pid = propertyId, let saj = serviceAccountJson else { return false }
        return !pid.isEmpty && !saj.isEmpty
    }

    // MARK: connect / disconnect

    func connect(credentials: [String: String]) throws {
        let pid = (credentials["propertyId"] ?? "").trimmingCharacters(in: .whitespaces)
        let saj = (credentials["serviceAccountJson"] ?? "").trimmingCharacters(in: .whitespaces)

        guard !pid.isEmpty else { throw ConnectorError.missingCredential("propertyId") }
        guard !saj.isEmpty else { throw ConnectorError.missingCredential("serviceAccountJson") }

        propertyId        = pid
        serviceAccountJson = saj
    }

    func disconnect() {
        propertyId         = nil
        serviceAccountJson = nil
        cachedAccessToken  = nil
        tokenExpiry        = nil
    }

    // MARK: query

    func query(intent: ConnectorIntent) async throws -> ConnectorResult {
        guard isConnected, let pid = propertyId else {
            throw ConnectorError.notConnected(name)
        }

        let token = try await getAccessToken()

        let startStr = dateString(from: intent.timeRange.startDate)
        let endStr   = dateString(from: intent.timeRange.endDate)

        let urlString = "https://analyticsdata.googleapis.com/v1beta/properties/\(pid)/runReport"
        guard let url = URL(string: urlString) else {
            throw ConnectorError.apiError("Invalid URL: \(urlString)")
        }

        let body: [String: Any] = [
            "dateRanges": [
                ["startDate": startStr, "endDate": endStr]
            ],
            "dimensions": [
                ["name": "date"]
            ],
            "metrics": [
                ["name": "sessions"],
                ["name": "activeUsers"],
                ["name": "screenPageViews"],
                ["name": "conversions"],
                ["name": "bounceRate"]
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError.apiError("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "(empty)"
            throw ConnectorError.apiError("Google Analytics API returned \(http.statusCode): \(body)")
        }

        // MARK: Parse response

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = json["rows"] as? [[String: Any]]
        else {
            // No rows means no data for the period — return zeroes
            let heading = intent.timeRange.displayName.prefix(1).uppercased()
                + intent.timeRange.displayName.dropFirst()
            let answer = """
                ## Google Analytics \u{2014} \(heading)

                **Sessions:** 0
                **Users:** 0
                **Page Views:** 0
                **Conversions:** 0
                **Bounce Rate:** 0%
                """
            return ConnectorResult(
                connectorId:   id,
                connectorName: name,
                icon:          icon,
                answer:        answer,
                rawData:       [:],
                timeRange:     intent.timeRange,
                cachedAt:      Date()
            )
        }

        var totalSessions:   Int    = 0
        var totalUsers:      Int    = 0
        var totalPageViews:  Int    = 0
        var totalConversions: Int   = 0
        var bounceRateSum:   Double = 0
        var bounceRateCount: Int    = 0

        for row in rows {
            guard let metricValues = row["metricValues"] as? [[String: Any]] else { continue }

            // Metrics are returned in the same order as requested:
            // 0: sessions, 1: activeUsers, 2: screenPageViews, 3: conversions, 4: bounceRate
            func intValue(at index: Int) -> Int {
                guard index < metricValues.count,
                      let str = metricValues[index]["value"] as? String,
                      let val = Int(str) else { return 0 }
                return val
            }

            func doubleValue(at index: Int) -> Double? {
                guard index < metricValues.count,
                      let str = metricValues[index]["value"] as? String else { return nil }
                return Double(str)
            }

            totalSessions    += intValue(at: 0)
            totalUsers       += intValue(at: 1)
            totalPageViews   += intValue(at: 2)
            totalConversions += intValue(at: 3)

            if let br = doubleValue(at: 4) {
                bounceRateSum   += br
                bounceRateCount += 1
            }
        }

        // bounceRate in GA4 is a decimal 0–1; average across rows then convert to %
        let avgBounceRate: Double
        if bounceRateCount > 0 {
            avgBounceRate = (bounceRateSum / Double(bounceRateCount)) * 100.0
        } else {
            avgBounceRate = 0
        }
        let bounceRateFormatted = String(format: "%.1f", avgBounceRate)

        // MARK: Build answer

        let heading = intent.timeRange.displayName.prefix(1).uppercased()
            + intent.timeRange.displayName.dropFirst()

        let answer = """
            ## Google Analytics \u{2014} \(heading)

            **Sessions:** \(totalSessions)
            **Users:** \(totalUsers)
            **Page Views:** \(totalPageViews)
            **Conversions:** \(totalConversions)
            **Bounce Rate:** \(bounceRateFormatted)%
            """

        let rawData: [String: Any] = [
            "rows":        rows,
            "sessions":    totalSessions,
            "users":       totalUsers,
            "pageViews":   totalPageViews,
            "conversions": totalConversions,
            "bounceRate":  avgBounceRate
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

    // MARK: - Access Token

    private func getAccessToken() async throws -> String {
        // Return cached token if still valid (with 60-second buffer)
        if let token = cachedAccessToken,
           let expiry = tokenExpiry,
           expiry > Date().addingTimeInterval(60) {
            return token
        }

        guard let saj = serviceAccountJson else {
            throw ConnectorError.missingCredential("serviceAccountJson")
        }

        // Parse service account JSON
        guard
            let sajData = saj.data(using: .utf8),
            let sajDict = try? JSONSerialization.jsonObject(with: sajData) as? [String: Any],
            let clientEmail = sajDict["client_email"] as? String,
            let privateKeyPEM = sajDict["private_key"] as? String
        else {
            throw ConnectorError.parseError("Invalid service account JSON — expected client_email and private_key")
        }

        let now = Date()
        let iat = Int(now.timeIntervalSince1970)
        let exp = iat + 3600

        let header: [String: Any] = [
            "alg": "RS256",
            "typ": "JWT"
        ]
        let claims: [String: Any] = [
            "iss":   clientEmail,
            "scope": "https://www.googleapis.com/auth/analytics.readonly",
            "aud":   "https://oauth2.googleapis.com/token",
            "iat":   iat,
            "exp":   exp
        ]

        let jwt = try signJWT(header: header, claims: claims, privateKeyPEM: privateKeyPEM)

        // Exchange JWT for access token
        guard let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else {
            throw ConnectorError.apiError("Invalid token endpoint URL")
        }

        let grantType = "urn:ietf:params:oauth:grant-type:jwt-bearer"
        let bodyString = "grant_type=\(grantType.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? grantType)&assertion=\(jwt)"

        var tokenRequest = URLRequest(url: tokenURL, timeoutInterval: 15)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        tokenRequest.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: tokenRequest)

        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError.apiError("No HTTP response from token endpoint")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "(empty)"
            throw ConnectorError.apiError("Token endpoint returned \(http.statusCode): \(body)")
        }

        guard
            let tokenJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = tokenJson["access_token"] as? String
        else {
            throw ConnectorError.parseError("Could not parse access_token from token response")
        }

        let expiresIn = tokenJson["expires_in"] as? Double ?? 3600
        cachedAccessToken = accessToken
        tokenExpiry = now.addingTimeInterval(expiresIn)

        return accessToken
    }

    // MARK: - JWT Signing

    private func signJWT(header: [String: Any], claims: [String: Any], privateKeyPEM: String) throws -> String {
        // Encode header and claims
        guard
            let headerData  = try? JSONSerialization.data(withJSONObject: header,  options: [.sortedKeys]),
            let claimsData  = try? JSONSerialization.data(withJSONObject: claims,  options: [.sortedKeys])
        else {
            throw ConnectorError.parseError("Could not serialize JWT header or claims")
        }

        let encodedHeader = base64URLEncode(headerData)
        let encodedClaims = base64URLEncode(claimsData)
        let signingInput  = "\(encodedHeader).\(encodedClaims)"

        // Strip PEM armor and newlines to get raw DER bytes
        var pem = privateKeyPEM
        pem = pem.replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
        pem = pem.replacingOccurrences(of: "-----END PRIVATE KEY-----",   with: "")
        pem = pem.replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
        pem = pem.replacingOccurrences(of: "-----END RSA PRIVATE KEY-----",   with: "")
        pem = pem.replacingOccurrences(of: "\n", with: "")
        pem = pem.replacingOccurrences(of: "\r", with: "")
        pem = pem.trimmingCharacters(in: .whitespaces)

        guard let derData = Data(base64Encoded: pem) else {
            throw ConnectorError.parseError("Could not base64-decode private key PEM")
        }

        // Create SecKey from DER data
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String:  kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048
        ]

        var cfError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(derData as CFData, keyAttributes as CFDictionary, &cfError) else {
            let errDesc = cfError?.takeRetainedValue().localizedDescription ?? "unknown"
            throw ConnectorError.parseError("Could not create SecKey: \(errDesc)")
        }

        // Sign with RSASSA-PKCS1-v1_5 SHA-256
        guard let signingInputData = signingInput.data(using: .utf8) else {
            throw ConnectorError.parseError("Could not encode signing input as UTF-8")
        }

        guard let signatureData = SecKeyCreateSignature(
            secKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            signingInputData as CFData,
            &cfError
        ) as Data? else {
            let errDesc = cfError?.takeRetainedValue().localizedDescription ?? "unknown"
            throw ConnectorError.parseError("Could not sign JWT: \(errDesc)")
        }

        let encodedSignature = base64URLEncode(signatureData)
        return "\(signingInput).\(encodedSignature)"
    }

    // MARK: - Helpers

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func dateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
