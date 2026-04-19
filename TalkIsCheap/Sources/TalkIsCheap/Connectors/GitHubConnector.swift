import Foundation

// MARK: - GitHubConnector

final class GitHubConnector: Connector {

    // MARK: Shared instance

    static let shared = GitHubConnector()
    private init() {}

    // MARK: Connector identity

    let id = "github"
    let name = "GitHub"
    let icon = "chevron.left.forwardslash.chevron.right"
    let accentColorHex = "#24292E"

    let keywords: [String] = [
        "github", "git", "issues", "pull request", "pullrequest",
        "pr", "prs", "bugs", "fehler", "commits", "repository",
        "repo", "code", "branch", "branches", "merge",
        "open issues", "offene issues", "deployment"
    ]

    let serviceNames: [String] = ["github", "git hub", "git-hub"]
    let category: ConnectorCategory = .dev

    // Nango managed OAuth — opt-in. When the user clicks "Connect with
    // one click", we store the resulting connection ID and route all API
    // calls through /api/nango/proxy. Pasted-token flow still works as
    // a fallback.
    let nangoIntegrationKey: String? = "github-getting-started"

    let setupGuide: [SetupStep] = [
        SetupStep(
            "1. Create a fine-grained Personal Access Token",
            detail: "Fine-grained tokens are scoped per-repo and safer than classic PATs. This button opens the creation page directly.",
            actionLabel: "Create fine-grained PAT",
            actionURL: "https://github.com/settings/personal-access-tokens/new"
        ),
        SetupStep(
            "2. Token name + expiration",
            detail: "Name: \"TalkIsCheap\". Expiration: 1 year is a good default (shorter = safer, but you'll have to rotate). Resource owner: pick yourself or the org whose repos you want to query."
        ),
        SetupStep(
            "3. Repository access",
            detail: "\"All repositories\" covers everything under the resource owner. Or pick specific repos. \"Public repositories (read-only)\" is the most restrictive option."
        ),
        SetupStep(
            "4. Permissions — Repository access",
            detail: "Set the following to READ-only. Everything else stays 'No access':",
            copyable: "Contents: Read-only\nIssues: Read-only\nPull requests: Read-only\nMetadata: Read-only"
        ),
        SetupStep(
            "5. Generate token + copy once",
            detail: "GitHub shows the token on the next page — copy it immediately, you can't see it again. Starts with github_pat_."
        ),
        SetupStep(
            "6. Optional: pin a default repo",
            detail: "If you leave Owner + Repo empty below, \"open issues\" queries will look at all your repos. Set them to focus queries on one project (e.g. owner: bene, repo: TalkIsCheap)."
        ),
    ]

    // MARK: Credential fields

    let credentialFields: [(key: String, label: String, isSecret: Bool)] = [
        (key: "token", label: "Personal Access Token",          isSecret: true),
        (key: "owner", label: "Repository Owner (optional)",    isSecret: false),
        (key: "repo",  label: "Repository Name (optional)",     isSecret: false)
    ]

    // MARK: Private state

    private var token: String?
    private var owner: String?
    private var repo: String?
    /// Set when the user authorised via Nango OAuth (one-click).
    /// Takes precedence over `token` when present.
    private var nangoConnectionId: String?

    // MARK: isConnected

    var isConnected: Bool {
        if let id = nangoConnectionId, !id.isEmpty { return true }
        if let t = token, !t.isEmpty { return true }
        return false
    }

    // MARK: connect / disconnect

    func connect(credentials: [String: String]) throws {
        // Nango OAuth path — just a connection id, no scopes to paste.
        if let nid = credentials["nangoConnectionId"]?.trimmingCharacters(in: .whitespaces), !nid.isEmpty {
            nangoConnectionId = nid
            // Nango mode overrides pasted token. Keep owner/repo in case
            // the user set a focus repo manually.
            owner = credentials["owner"]?.trimmingCharacters(in: .whitespaces)
            repo  = credentials["repo"]?.trimmingCharacters(in: .whitespaces)
            token = nil
            return
        }

        // Legacy paste-token path.
        let t = (credentials["token"] ?? "").trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { throw ConnectorError.missingCredential("token") }

        token = t
        nangoConnectionId = nil
        owner = (credentials["owner"] ?? "").trimmingCharacters(in: .whitespaces)
        repo  = (credentials["repo"]  ?? "").trimmingCharacters(in: .whitespaces)
    }

    func disconnect() {
        token = nil
        owner = nil
        repo  = nil
        nangoConnectionId = nil
    }

    // MARK: query

    func query(intent: ConnectorIntent) async throws -> ConnectorResult {
        guard isConnected else { throw ConnectorError.notConnected(name) }

        let hasOwner = !(owner ?? "").isEmpty
        let hasRepo  = !(repo  ?? "").isEmpty

        if hasOwner && hasRepo, let ownerStr = owner, let repoStr = repo {
            return try await queryRepo(owner: ownerStr, repo: repoStr, intent: intent)
        } else {
            return try await queryUser(intent: intent)
        }
    }

    // MARK: Repo-scoped query

    private func queryRepo(
        owner: String,
        repo: String,
        intent: ConnectorIntent
    ) async throws -> ConnectorResult {
        let issuesPath = "/repos/\(owner)/\(repo)/issues?state=open&per_page=30"
        let pullsPath  = "/repos/\(owner)/\(repo)/pulls?state=open&per_page=20"

        async let issuesData = githubGet(path: issuesPath)
        async let pullsData  = githubGet(path: pullsPath)

        let (issuesRaw, pullsRaw) = try await (issuesData, pullsData)

        guard
            let issuesJSON = try? JSONSerialization.jsonObject(with: issuesRaw) as? [[String: Any]],
            let pullsJSON  = try? JSONSerialization.jsonObject(with: pullsRaw)  as? [[String: Any]]
        else {
            throw ConnectorError.parseError("Unexpected GitHub response shape")
        }

        // Filter out pull requests from the issues endpoint
        let issues = issuesJSON.filter { $0["pull_request"] == nil }
        let prs    = pullsJSON

        // Build answer
        var lines: [String] = [
            "## GitHub \u{2014} \(owner)/\(repo)",
            "",
            "**Open Issues:** \(issues.count)",
            "**Open Pull Requests:** \(prs.count)"
        ]

        // Recent issues (up to 5)
        lines.append("")
        lines.append("**Recent Issues:**")
        let recentIssues = issues.prefix(5)
        if recentIssues.isEmpty {
            lines.append("- No open issues")
        } else {
            for issue in recentIssues {
                let number = issue["number"] as? Int ?? 0
                let title  = issue["title"]  as? String ?? "(no title)"
                lines.append("- #\(number): \(title)")
            }
        }

        // Open PRs (up to 5)
        lines.append("")
        lines.append("**Open PRs:**")
        let recentPRs = prs.prefix(5)
        if recentPRs.isEmpty {
            lines.append("- No open pull requests")
        } else {
            for pr in recentPRs {
                let number = pr["number"] as? Int ?? 0
                let title  = pr["title"]  as? String ?? "(no title)"
                lines.append("- #\(number): \(title)")
            }
        }

        let answer = lines.joined(separator: "\n")

        let rawData: [String: Any] = [
            "issues": issuesJSON,
            "pulls":  pullsJSON,
            "issueCount": issues.count,
            "prCount":    prs.count
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

    // MARK: User-scoped query

    private func queryUser(intent: ConnectorIntent) async throws -> ConnectorResult {
        async let userData  = githubGet(path: "/user")
        async let reposData = githubGet(path: "/user/repos?sort=updated&per_page=10")

        let (userRaw, reposRaw) = try await (userData, reposData)

        guard
            let userJSON  = try? JSONSerialization.jsonObject(with: userRaw)  as? [String: Any],
            let reposJSON = try? JSONSerialization.jsonObject(with: reposRaw) as? [[String: Any]]
        else {
            throw ConnectorError.parseError("Unexpected GitHub response shape")
        }

        let login = userJSON["login"] as? String ?? "Unknown"

        var lines: [String] = [
            "## GitHub \u{2014} \(login)",
            "",
            "**Recently Updated Repositories:**"
        ]

        let top5 = reposJSON.prefix(5)
        if top5.isEmpty {
            lines.append("- No repositories found")
        } else {
            for repo in top5 {
                let repoName    = repo["full_name"]    as? String ?? repo["name"] as? String ?? "(unknown)"
                let openIssues  = repo["open_issues_count"] as? Int ?? 0
                lines.append("- \(repoName) — \(openIssues) open issue\(openIssues == 1 ? "" : "s")")
            }
        }

        let answer = lines.joined(separator: "\n")

        let rawData: [String: Any] = [
            "user":  userJSON,
            "repos": reposJSON
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

    /// Routes a GitHub path either through Nango (when OAuth'd) or
    /// directly to api.github.com (when the user pasted a PAT).
    private func githubGet(path: String) async throws -> Data {
        if let connectionId = nangoConnectionId, !connectionId.isEmpty,
           let integrationKey = nangoIntegrationKey {
            return try await NangoClient.shared.proxy(
                integrationKey: integrationKey,
                connectionId: connectionId,
                path: path,
                method: "GET"
            )
        }
        guard let tok = token, !tok.isEmpty else {
            throw ConnectorError.notConnected(name)
        }
        return try await directGitHubGet(path: path, token: tok)
    }

    private func directGitHubGet(path: String, token: String) async throws -> Data {
        let fullURL = "https://api.github.com\(path)"
        guard let requestURL = URL(string: fullURL) else {
            throw ConnectorError.apiError("Invalid URL: \(fullURL)")
        }

        var request = URLRequest(url: requestURL, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)",                  forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json",      forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28",                       forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError.apiError("No HTTP response")
        }

        switch http.statusCode {
        case 200:
            return data
        case 401:
            throw ConnectorError.apiError("Invalid GitHub token")
        default:
            throw ConnectorError.apiError("GitHub API error: HTTP \(http.statusCode)")
        }
    }
}
