import Foundation

/// Speech-to-text via Groq Cloud API or local mlx-whisper
final class TranscriberService {
    static let shared = TranscriberService()

    func transcribe(wavData: Data, language: String?) async throws -> String {
        let settings = AppSettings.shared
        let dict = settings.customDictionary.isEmpty ? nil : settings.customDictionary

        // Use our cloud proxy for Trial + Pro users
        if settings.shouldUseProxy {
            return try await ProxyClient.transcribe(wavData: wavData, language: language, dictionary: dict)
        }

        if settings.sttProvider == "local" {
            return try await transcribeLocal(wavData: wavData, language: language)
        } else {
            return try await transcribeGroq(wavData: wavData, language: language, dictionary: dict)
        }
    }

    // MARK: - Groq Cloud

    private func transcribeGroq(wavData: Data, language: String?, dictionary: String? = nil) async throws -> String {
        let apiKey = AppSettings.shared.groqApiKey
        guard !apiKey.isEmpty else {
            throw TranscriberError.noApiKey
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-large-v3\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)

        if let lang = language, lang != "auto", !lang.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(lang)\r\n".data(using: .utf8)!)
        }

        // Custom vocabulary — helps Whisper recognize proper nouns, company names, technical terms
        if let dict = dictionary, !dict.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(dict)\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriberError.apiError(errorText)
        }

        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Local (mlx-whisper via Python venv)

    private func transcribeLocal(wavData: Data, language: String?) async throws -> String {
        let pythonPath = await MainActor.run { LocalSetupService.shared.venvPythonPath }

        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            throw TranscriberError.localNotSetup
        }

        // Write WAV to temp file
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("talkischeap_\(UUID().uuidString).wav")
        try wavData.write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let langArg = (language != nil && language != "auto") ? "'\(language!)'" : "None"

        let script = """
        import mlx_whisper, sys
        result = mlx_whisper.transcribe(
            sys.argv[1],
            path_or_hf_repo='mlx-community/whisper-large-v3-turbo',
            language=\(langArg)
        )
        print(result.get('text', ''))
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-c", script, tmpFile.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if text.isEmpty && process.terminationStatus != 0 {
            throw TranscriberError.localError("mlx-whisper failed (exit \(process.terminationStatus))")
        }

        return text
    }
}

enum TranscriberError: LocalizedError {
    case noApiKey
    case apiError(String)
    case localNotSetup
    case localError(String)

    var errorDescription: String? {
        switch self {
        case .noApiKey: return "No Groq API key configured"
        case .apiError(let msg): return "Groq API error: \(msg)"
        case .localNotSetup: return "Local mode not set up. Run setup from Settings."
        case .localError(let msg): return "Local transcription error: \(msg)"
        }
    }
}
