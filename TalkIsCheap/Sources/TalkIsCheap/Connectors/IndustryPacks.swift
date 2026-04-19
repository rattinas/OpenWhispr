import Foundation

/// Curated "which tools are relevant for my business" bundles.
/// The Settings UI lets the user pick one and we surface the matching
/// integrations first, so a Shopify-store owner doesn't have to scroll
/// past recruiting tools to find Stripe.
///
/// Each pack matches on the Nango provider name (the canonical upstream
/// identifier, e.g. "shopify", "google-ads") — so new integrations
/// added in the Nango dashboard automatically slot into the right
/// pack without a code change.
struct IndustryPack: Identifiable, Hashable {
    let id: String            // short slug
    let emoji: String
    let name: String          // localized display label
    let tagline: String       // one-sentence pitch
    /// Providers recommended for this pack. Ordered (most core tools first).
    let providers: [String]

    static let all: [IndustryPack] = [
        IndustryPack(
            id: "personal",
            emoji: "💬",
            name: "Personal Inbox",
            tagline: "Email, calendar, notes — ask about your own communication & life.",
            providers: [
                "google-mail", "microsoft-outlook", "yahoo-mail",
                "google-calendar", "microsoft-calendar", "calendly",
                "notion", "google-drive", "dropbox", "evernote",
                "slack", "discord", "whatsapp-business",
                "todoist", "things", "reminders",
            ]
        ),
        IndustryPack(
            id: "ecommerce",
            emoji: "🛍",
            name: "E-Commerce",
            tagline: "Orders, revenue, ad spend and conversions for your online store.",
            providers: [
                "shopify", "woocommerce", "bigcommerce", "squarespace",
                "stripe", "paypal", "klarna", "paddle",
                "klaviyo", "mailchimp", "postmark", "sendgrid",
                "google-analytics", "google-ads", "facebook-ads", "tiktok-ads",
                "google-mail", "microsoft-outlook",
                "gorgias", "zendesk", "intercom",
            ]
        ),
        IndustryPack(
            id: "marketing",
            emoji: "📈",
            name: "Marketing Agency",
            tagline: "Run ad performance, audience insights and reporting across channels.",
            providers: [
                "google-ads", "facebook-ads", "instagram", "tiktok-ads",
                "linkedin-ads", "twitter-ads", "pinterest-ads", "snapchat",
                "google-analytics", "mixpanel", "amplitude", "posthog",
                "hubspot", "salesforce", "pipedrive", "activecampaign",
                "mailchimp", "klaviyo", "sendgrid", "braze",
                "ahrefs", "semrush", "brandwatch",
            ]
        ),
        IndustryPack(
            id: "saas",
            emoji: "🧪",
            name: "SaaS / Product",
            tagline: "MRR, churn, active users, deploys and issue tracking.",
            providers: [
                "stripe", "chargebee", "paddle",
                "mixpanel", "amplitude", "posthog", "heap",
                "hubspot", "intercom", "segment",
                "github", "gitlab", "linear", "jira", "notion",
                "sentry", "datadog", "vercel", "netlify",
                "slack", "discord",
            ]
        ),
        IndustryPack(
            id: "dev",
            emoji: "💻",
            name: "Developer / Engineering",
            tagline: "Repos, CI runs, PRs, deployment status and errors.",
            providers: [
                "github", "gitlab", "bitbucket",
                "linear", "jira", "asana", "notion",
                "sentry", "datadog", "pagerduty",
                "vercel", "netlify", "cloudflare", "aws", "gcp",
                "slack", "discord", "microsoft-teams",
            ]
        ),
        IndustryPack(
            id: "recruiting",
            emoji: "🧑‍💼",
            name: "Recruiting & HR",
            tagline: "Candidates, interviews, offers, hiring pipeline.",
            providers: [
                "greenhouse", "lever", "workable", "ashby",
                "linkedin", "indeed", "gem",
                "bamboohr", "workday", "gusto", "rippling",
                "calendly", "slack",
            ]
        ),
        IndustryPack(
            id: "consulting",
            emoji: "📋",
            name: "Consulting / Services",
            tagline: "Projects, time, invoices, client communications.",
            providers: [
                "notion", "linear", "asana", "trello", "clickup", "airtable",
                "slack", "microsoft-teams", "zoom", "google-calendar",
                "calendly",
                "hubspot", "pipedrive",
                "stripe", "quickbooks", "xero",
                "dropbox", "google-drive", "onedrive",
            ]
        ),
        IndustryPack(
            id: "content",
            emoji: "🎬",
            name: "Content Creator",
            tagline: "Reach, engagement, monetization across platforms.",
            providers: [
                "youtube", "tiktok", "instagram", "twitter", "linkedin",
                "twitch", "patreon", "ko-fi", "gumroad",
                "google-analytics", "mixpanel",
                "mailchimp", "substack", "beehiiv",
                "notion", "airtable",
            ]
        ),
    ]

    /// Position of a provider within this pack (lower = more relevant).
    /// Providers not listed here return nil (not in pack).
    func priority(for provider: String) -> Int? {
        providers.firstIndex(where: { $0.lowercased() == provider.lowercased() })
    }
}
