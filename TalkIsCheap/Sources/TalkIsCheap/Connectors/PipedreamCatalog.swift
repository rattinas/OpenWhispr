import Foundation
import SwiftUI

/// Catalog of every Pipedream Connect app (~2000+) plus the accounts
/// the current licensee has connected. Drives the Services settings
/// tab.
@MainActor
final class PipedreamCatalog: ObservableObject {
    static let shared = PipedreamCatalog()
    private init() {}

    @Published private(set) var apps: [PipedreamClient.AppInfo] = []
    @Published private(set) var accounts: [PipedreamClient.Account] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    /// Run a live-search against Pipedream's full catalogue and REPLACE
    /// the published `apps` with the results. Used when the user types
    /// into the search field so they can discover less common apps.
    func search(_ query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await refresh()
            return
        }
        isLoading = true
        loadError = nil
        do {
            let result = try await PipedreamClient.shared.apps(query: query)
            self.apps = result
        } catch {
            self.loadError = "Search failed: \(error.localizedDescription)"
        }
        isLoading = false
    }

    func refresh() async {
        isLoading = true
        loadError = nil

        // Run both requests independently so we see *which* failed and why.
        var appsErr: Error?
        var accountsErr: Error?
        async let appsFuture: [PipedreamClient.AppInfo]? = Task {
            do { return try await PipedreamClient.shared.apps() }
            catch { appsErr = error; return nil }
        }.value
        async let accountsFuture: [PipedreamClient.Account]? = Task {
            do { return try await PipedreamClient.shared.listAccounts() }
            catch { accountsErr = error; return nil }
        }.value
        let (newApps, newAccounts) = await (appsFuture, accountsFuture)

        if let list = newApps {
            self.apps = list.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        if let list = newAccounts { self.accounts = list }

        if newApps == nil || newAccounts == nil {
            let parts = [
                appsErr.map { "apps: \($0.localizedDescription)" },
                accountsErr.map { "accounts: \($0.localizedDescription)" }
            ].compactMap { $0 }
            self.loadError = parts.isEmpty ? "Couldn't reach TalkIsCheap Server." : parts.joined(separator: " · ")
        }
        isLoading = false
    }

    /// Returns the healthy account for a given app slug, if connected.
    func account(forApp slug: String) -> PipedreamClient.Account? {
        accounts.first { $0.appSlug.lowercased() == slug.lowercased() && ($0.healthy ?? true) }
    }

    /// True when any healthy account exists for the given app slug.
    func isConnected(app slug: String) -> Bool {
        account(forApp: slug) != nil
    }

    /// Seed the accounts list if the catalog hasn't been loaded yet —
    /// so the first voice query after a fresh app launch finds the
    /// user's connections even if they haven't opened Settings.
    func ensureAccountsLoaded() async {
        guard accounts.isEmpty else { return }
        if let list = try? await PipedreamClient.shared.listAccounts() {
            self.accounts = list
        }
    }
}

// MARK: - Connector convenience: Pipedream-proxied upstream calls

extension Connector {
    /// Makes a Pipedream-proxied upstream request if a live account
    /// exists for this connector's `pipedreamAppSlug`. Throws
    /// `ConnectorError.notConnected` if no account is available.
    @MainActor
    func pipedreamProxy(
        url: String,
        method: String = "GET",
        body: Any? = nil
    ) async throws -> Data {
        guard let slug = pipedreamAppSlug else {
            throw ConnectorError.notConnected(name)
        }
        await PipedreamCatalog.shared.ensureAccountsLoaded()
        guard let account = PipedreamCatalog.shared.account(forApp: slug) else {
            throw ConnectorError.notConnected(name)
        }
        return try await PipedreamClient.shared.proxy(
            accountId: account.id,
            url: url,
            method: method,
            body: body
        )
    }

    /// True when PipedreamCatalog reports a live account for this
    /// connector's `pipedreamAppSlug`.
    @MainActor
    var isPipedreamConnected: Bool {
        guard let slug = pipedreamAppSlug else { return false }
        return PipedreamCatalog.shared.account(forApp: slug) != nil
    }

    /// Map app slug → known category. Uses Pipedream's `categories`
    /// field when available, else falls back to a regex classifier
    /// similar to the server-side Nango one so the UI groups nicely.
    func category(for app: PipedreamClient.AppInfo) -> String {
        if let first = app.categories.first?.lowercased() {
            // Pipedream has a lot of categories; map common ones onto our buckets.
            switch first {
            case let c where c.contains("e-comm") || c.contains("payment") || c.contains("commerce"):
                return "ecommerce"
            case let c where c.contains("marketing") || c.contains("analytic") || c.contains("advertising") || c.contains("ads"):
                return "marketing"
            case let c where c.contains("developer") || c.contains("dev tool") || c.contains("code") || c.contains("version"):
                return "dev"
            case let c where c.contains("hr") || c.contains("recruit") || c.contains("hiring"):
                return "recruiting"
            case let c where c.contains("productivity") || c.contains("project") || c.contains("storage") || c.contains("note") || c.contains("document"):
                return "productivity"
            case let c where c.contains("communication") || c.contains("email") || c.contains("chat") || c.contains("messaging"):
                return "productivity"
            default:
                break
            }
        }
        // Fallback: match on slug.
        let slug = app.slug.lowercased()
        let groups: [(String, [String])] = [
            ("ecommerce", ["shopify", "woocommerce", "bigcommerce", "stripe", "paypal", "paddle", "square", "braintree"]),
            ("marketing", ["google_analytics", "google_ads", "facebook_ads", "meta_ads", "linkedin_ads", "tiktok_ads", "mailchimp", "klaviyo", "hubspot", "mixpanel", "amplitude", "posthog"]),
            ("dev", ["github", "gitlab", "bitbucket", "linear", "jira", "sentry", "vercel", "netlify", "datadog"]),
            ("recruiting", ["greenhouse", "lever", "workable", "bamboohr", "indeed"]),
            ("productivity", ["google_sheets", "google_drive", "gmail", "google_calendar", "notion", "airtable", "slack", "discord", "microsoft_teams", "zoom", "calendly", "dropbox"]),
        ]
        for (cat, keys) in groups {
            if keys.contains(where: { slug.contains($0) }) { return cat }
        }
        return "other"
    }
}
