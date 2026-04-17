import Foundation

/// Text polishing via Anthropic Claude API or local Ollama
final class PolisherService {
    static let shared = PolisherService()

    func polish(text: String, mode: PolishMode, extraContext: String = "", altTranscript: String? = nil) async throws -> String {
        // Raw mode = no polishing
        guard let prompt = mode.prompt else { return text }

        let settings = AppSettings.shared
        var systemPrompt = prompt
        if !extraContext.isEmpty {
            systemPrompt += "\n" + extraContext
        }

        // Second-opinion transcript (from a different engine) helps the model
        // resolve ambiguous words. Where both transcripts agree, use that word.
        // Where they differ, pick the one that makes sense in context.
        if let alt = altTranscript, !alt.isEmpty {
            systemPrompt += """

            <alt_transcript>
            A second speech-to-text engine transcribed the same audio as this:
            \(alt)

            Use it as a hint when the primary transcript (the USER message below)
            has an obviously misheard word. Do not merge the two transcripts —
            output the corrected version of the primary transcript only.
            </alt_transcript>
            """
        }

        // Compact hint: the input is speech-to-text, so obvious misheard
        // words may appear. Correcting them has priority over the
        // "preserve meaning" rule in mode prompts.
        systemPrompt += """

        <transcription>
        Input is speech-to-text output. Silently fix obvious recognition
        errors using context; correction wins over "preserve meaning" when
        the intended word is unambiguous.

        The speaker is often a German developer who drops English tech/
        business words mid-sentence (Denglish). When a German-looking word
        doesn't fit the sentence, assume it is a mis-transcribed English
        word. Typical pattern: imminiert → immediate, deployen → deploy,
        committen → commit, push-en → push, launchen → launch, kanzeln →
        cancel, plänen → plannen, abfeature-t → featured.

        Tech-brand mishearings to fix: deep gram/deepcrime → Deepgram ·
        entropic/anthropics → Anthropic · clod → Claude · grok/grog →
        Groq · whisper flow → Wispr Flow · spotifai → Spotify.

        Keep the speaker's language; never translate. Never add greetings,
        sign-offs, commentary, or preamble.
        Output ONLY the polished text.
        </transcription>
        """

        // Inject custom dictionary context for better proper noun handling
        let dict = settings.customDictionary
        if !dict.isEmpty {
            systemPrompt += "\n\n<dictionary>\nThe user commonly uses these proper nouns, company names, or technical terms. Preserve them exactly and, if the engine mis-transcribed one, restore the correct form:\n\(dict)\n</dictionary>"
        }

        // Model selection per mode, tuned for what each mode actually does:
        //   - "clean" → light formatting only. Llama 3.1 8B Instant: tiny,
        //     blazing fast (~1200 tok/s), perfect for the formatter role.
        //   - "polish" → thoughtful rewrite of stream-of-consciousness. Claude
        //     Haiku 4.5 handles nuance much better than small Llama.
        //   - "coding" → precise technical text. Claude Sonnet 4.6.
        //   - everything else (professional, marketing, email, casual,
        //     prompt modes, custom) → Llama 3.3 70B as a solid default.
        let polishModel: String
        switch mode.id {
        case "clean":
            polishModel = "llama-3.1-8b-instant"
        case "polish":
            polishModel = "claude-haiku-4-5-20251001"
        case "coding":
            polishModel = "claude-sonnet-4-6"
        default:
            polishModel = "llama-3.3-70b-versatile"
        }

        // Pro / Trial users use our proxy — the proxy routes to Anthropic
        // or Groq based on the model name prefix.
        if settings.shouldUseProxy {
            return try await ProxyClient.polish(text: text, systemPrompt: systemPrompt, model: polishModel)
        }

        if settings.polishProvider == "ollama" {
            return try await polishOllama(text: text, system: systemPrompt)
        }

        // BYOK direct path: Groq LLMs go to Groq, Claude models go to Anthropic.
        if polishModel.hasPrefix("claude-") {
            return try await polishClaude(text: text, system: systemPrompt, model: polishModel)
        } else {
            return try await polishGroq(text: text, system: systemPrompt, model: polishModel)
        }
    }

    // MARK: - Groq LLM (fast polish via Llama)

    private func polishGroq(text: String, system: String, model: String) async throws -> String {
        let apiKey = AppSettings.shared.groqApiKey
        guard !apiKey.isEmpty else {
            Log.write("Polish (Groq): no Groq key — returning raw text")
            return text
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text]
            ],
            "max_tokens": 1024,
            "temperature": 0.2,
        ]

        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown"
            throw PolisherError.apiError("Groq \((response as? HTTPURLResponse)?.statusCode ?? -1): \(errorText.prefix(200))")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let choices = json["choices"] as? [[String: Any]] ?? []
        let firstMessage = choices.first?["message"] as? [String: Any]
        let content = firstMessage?["content"] as? String ?? text
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Anthropic Claude

    private func polishClaude(text: String, system: String, model: String) async throws -> String {
        let apiKey = AppSettings.shared.anthropicApiKey
        guard !apiKey.isEmpty else {
            Log.write("Polish: no Anthropic key — returning raw text (set key in Settings → API Keys, or enable Cloud mode)")
            return text
        }

        let requestBody: [String: Any] = [
            "model": model,
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
