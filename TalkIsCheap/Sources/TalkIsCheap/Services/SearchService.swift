import Foundation

struct SearchSource {
    let title: String
    let url: String
    let thumbnail: String? // image URL if available
}

struct SearchResult {
    let query: String
    let answer: String
    let sources: [SearchSource]
    let images: [String] // image URLs from search results
}

/// Voice search: Brave Search + Claude Opus
final class SearchService {
    static let shared = SearchService()

    func search(query: String) async throws -> SearchResult {
        Log.write("Search: \(query)")

        // Pro / Trial users use our proxy (bundles Brave + Claude in one call)
        if AppSettings.shared.shouldUseProxy {
            let language = AppSettings.shared.language == "auto" ? nil : AppSettings.shared.language
            let proxyResult = try await ProxyClient.search(query: query, language: language)
            let sources = proxyResult.sources.map { SearchSource(title: $0.title, url: $0.url, thumbnail: nil) }
            return SearchResult(query: query, answer: proxyResult.answer, sources: sources, images: proxyResult.images)
        }

        // 1. Get web + image results from Brave
        let (webResults, imageURLs) = try await braveSearch(query: query)
        Log.write("Brave: \(webResults.count) results, \(imageURLs.count) images")

        // 2. Summarize with Claude Opus
        let depth = AppSettings.shared.searchDepth
        let answer = try await summarizeWithClaude(query: query, results: webResults, depth: depth)
        Log.write("Claude answer: \(answer.prefix(100))...")

        let sources = webResults.map { SearchSource(title: $0.title, url: $0.url, thumbnail: $0.thumbnail) }
        return SearchResult(query: query, answer: answer, sources: sources, images: imageURLs)
    }

    // MARK: - Brave Search

    private struct BraveResult {
        let title: String
        let url: String
        let snippet: String
        let thumbnail: String?
    }

    private func braveSearch(query: String) async throws -> ([BraveResult], [String]) {
        let apiKey = AppSettings.shared.braveApiKey
        guard !apiKey.isEmpty else {
            throw SearchError.noApiKey("Set Brave Search API key in Settings → API Keys")
        }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string: "https://api.search.brave.com/res/v1/web/search?q=\(encoded)&count=6&extra_snippets=true")!

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], [])
        }

        // Web results
        var webResults: [BraveResult] = []
        if let web = json["web"] as? [String: Any], let results = web["results"] as? [[String: Any]] {
            webResults = results.prefix(6).compactMap { r in
                guard let title = r["title"] as? String,
                      let url = r["url"] as? String,
                      let desc = r["description"] as? String
                else { return nil }
                let thumb = (r["thumbnail"] as? [String: Any])?["src"] as? String
                return BraveResult(title: title, url: url, snippet: desc, thumbnail: thumb)
            }
        }

        // Image results (from infobox or dedicated)
        var imageURLs: [String] = []
        if let infobox = json["infobox"] as? [String: Any],
           let images = infobox["images"] as? [[String: Any]] {
            imageURLs = images.prefix(3).compactMap { $0["src"] as? String }
        }
        // Also check thumbnail from web results
        for r in webResults {
            if let thumb = r.thumbnail, !imageURLs.contains(thumb) {
                imageURLs.append(thumb)
            }
            if imageURLs.count >= 4 { break }
        }

        return (webResults, imageURLs)
    }

    // MARK: - Claude Opus Summarization

    private func summarizeWithClaude(query: String, results: [BraveResult], depth: String) async throws -> String {
        let apiKey = AppSettings.shared.anthropicApiKey
        guard !apiKey.isEmpty else {
            return results.map { "**\($0.title)**\n\($0.snippet)" }.joined(separator: "\n\n")
        }

        let context = results.enumerated().map { i, r in
            "[\(i+1)] \(r.title)\n\(r.url)\n\(r.snippet)"
        }.joined(separator: "\n\n")

        let depthInstruction: String
        let maxTokens: Int
        switch depth {
        case "minimal":
            depthInstruction = "Answer in 1-2 sentences maximum. Be extremely brief. No fluff."
            maxTokens = 256
        case "detailed":
            depthInstruction = "Give a comprehensive, detailed answer. Use paragraphs, explain context, provide nuance. Be thorough."
            maxTokens = 4096
        default: // balanced
            depthInstruction = "Give a clear, concise answer in 2-4 sentences. Include key facts."
            maxTokens = 1024
        }

        let systemPrompt = """
        You are a search assistant. Answer the user's question using the search results.
        \(depthInstruction)
        Respond in the same language as the question.
        Reference sources as [1], [2] etc where relevant.
        """

        let requestBody: [String: Any] = [
            "model": AppSettings.shared.searchModel,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [["role": "user", "content": "Question: \(query)\n\nSearch Results:\n\(context)"]]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)

        let rawResponse = String(data: data, encoding: .utf8) ?? ""
        Log.write("Claude raw response: \(rawResponse.prefix(500))")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SearchError.parseError
        }

        // Handle error response
        if let error = json["error"] as? [String: Any], let msg = error["message"] as? String {
            Log.write("Claude API error: \(msg)")
            throw SearchError.noApiKey("Claude: \(msg)")
        }

        // Parse content — handle both text blocks and thinking blocks
        guard let content = json["content"] as? [[String: Any]] else {
            throw SearchError.parseError
        }

        // Find the text block (skip thinking blocks)
        let textBlock = content.first { ($0["type"] as? String) == "text" }
        guard let text = textBlock?["text"] as? String else {
            // Fallback: try first block's text
            if let text = content.first?["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            throw SearchError.parseError
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SearchError: LocalizedError {
    case noApiKey(String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .noApiKey(let msg): return msg
        case .parseError: return "Could not parse response"
        }
    }
}
