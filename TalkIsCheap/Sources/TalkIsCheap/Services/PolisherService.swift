import Foundation

/// Text polishing via Anthropic Claude API
final class PolisherService {
    static let shared = PolisherService()

    func polish(text: String, mode: PolishMode, extraContext: String = "") async throws -> String {
        // Raw mode = no polishing
        guard let prompt = mode.prompt else { return text }

        let settings = AppSettings.shared
        let apiKey = settings.anthropicApiKey
        guard !apiKey.isEmpty else {
            // No key = return raw text
            return text
        }

        var systemPrompt = prompt
        if !extraContext.isEmpty {
            systemPrompt += "\n" + extraContext
        }

        let requestBody: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": text]
            ]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw PolisherError.apiError(errorText)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let resultText = firstBlock["text"] as? String
        else {
            throw PolisherError.parseError
        }

        return resultText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum PolisherError: LocalizedError {
    case apiError(String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .apiError(let msg): return "Anthropic API error: \(msg)"
        case .parseError: return "Could not parse Anthropic response"
        }
    }
}
