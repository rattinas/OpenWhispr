import Foundation

/// Text polishing via Anthropic Claude API or local Ollama
final class PolisherService {
    static let shared = PolisherService()

    func polish(text: String, mode: PolishMode, extraContext: String = "") async throws -> String {
        // Raw mode = no polishing
        guard let prompt = mode.prompt else { return text }

        let settings = AppSettings.shared
        var systemPrompt = prompt
        if !extraContext.isEmpty {
            systemPrompt += "\n" + extraContext
        }

        // Inject custom dictionary context for better proper noun handling
        let dict = settings.customDictionary
        if !dict.isEmpty {
            systemPrompt += "\n\n<dictionary>\nThe user commonly uses these proper nouns, company names, or technical terms. Preserve them exactly:\n\(dict)\n</dictionary>"
        }

        // Pro / Trial users use our proxy
        if settings.shouldUseProxy {
            return try await ProxyClient.polish(text: text, systemPrompt: systemPrompt)
        }

        if settings.polishProvider == "ollama" {
            return try await polishOllama(text: text, system: systemPrompt)
        } else {
            return try await polishClaude(text: text, system: systemPrompt)
        }
    }

    // MARK: - Anthropic Claude

    private func polishClaude(text: String, system: String) async throws -> String {
        let apiKey = AppSettings.shared.anthropicApiKey
        guard !apiKey.isEmpty else { return text }

        let requestBody: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1024,
            "system": system,
            "messages": [["role": "user", "content": text]]
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

    // MARK: - Ollama (Local)

    private func polishOllama(text: String, system: String) async throws -> String {
        let requestBody: [String: Any] = [
            "model": "qwen2.5:3b",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text]
            ],
            "stream": false,
            "options": ["temperature": 0.1, "num_predict": 1024]
        ]

        var request = URLRequest(url: URL(string: "http://localhost:11434/api/chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Ollama not responding"
            throw PolisherError.ollamaError(errorText)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw PolisherError.parseError
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum PolisherError: LocalizedError {
    case apiError(String)
    case ollamaError(String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .apiError(let msg): return "Anthropic API error: \(msg)"
        case .ollamaError(let msg): return "Ollama error: \(msg)"
        case .parseError: return "Could not parse AI response"
        }
    }
}
