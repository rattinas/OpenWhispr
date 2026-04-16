import Foundation
import AppKit
import PDFKit

final class FileTranscriptionService {
    static let shared = FileTranscriptionService()

    private let maxChunkSize = 24 * 1024 * 1024
    private let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("talkischeap")

    /// File extensions that contain text (no audio transcription needed)
    private let documentExtensions = ["pdf", "docx"]

    /// Find ffmpeg binary — checks multiple paths for compatibility
    private func findFFmpeg() -> String? {
        let paths = [
            "/opt/homebrew/bin/ffmpeg",      // Apple Silicon Homebrew
            "/usr/local/bin/ffmpeg",          // Intel Homebrew
            "/usr/bin/ffmpeg",                // System
            "/opt/local/bin/ffmpeg",          // MacPorts
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Main pipeline

    func transcribe(filePath: String) async throws -> String {
        Log.write("FileTranscription: \(filePath)")

        let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()

        // Document files: extract text directly
        if documentExtensions.contains(ext) {
            return try extractText(filePath: filePath, ext: ext)
        }

        // Audio/video files: transcribe via STT
        let fm = FileManager.default
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // Step 1: Extract & compress audio with ffmpeg
        let compressedPath = try extractAndCompress(filePath: filePath)
        let compressedData = try Data(contentsOf: compressedPath)
        Log.write("Compressed: \(compressedData.count / 1024)KB")

        // Step 2: Transcribe based on provider setting
        let provider = AppSettings.shared.sttProvider
        let transcript: String

        if provider == "local" {
            transcript = try await transcribeLocal(audioPath: compressedPath.path)
        } else {
            let apiKey = AppSettings.shared.groqApiKey
            guard !apiKey.isEmpty else { throw FileTranscriptionError.noApiKey("Set Groq API key in Settings") }

            if compressedData.count <= maxChunkSize {
                transcript = try await transcribeGroq(data: compressedData, fileName: "audio.mp3", apiKey: apiKey)
            } else {
                transcript = try await transcribeGroqChunked(inputPath: compressedPath.path, apiKey: apiKey)
            }
        }

        cleanup()
        return transcript
    }

    // MARK: - Document text extraction

    private func extractText(filePath: String, ext: String) throws -> String {
        switch ext {
        case "pdf":
            return try extractPDFText(filePath: filePath)
        case "docx":
            return try extractDocxText(filePath: filePath)
        default:
            throw FileTranscriptionError.unsupportedFormat
        }
    }

    private func extractPDFText(filePath: String) throws -> String {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: filePath)) else {
            throw FileTranscriptionError.unsupportedFormat
        }
        var text = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let pageText = page.string {
                text += pageText + "\n"
            }
        }
        Log.write("PDF extracted: \(text.count) chars, \(doc.pageCount) pages")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FileTranscriptionError.apiError("PDF contains no extractable text (scanned/image-only PDF)")
        }
        return text
    }

    private func extractDocxText(filePath: String) throws -> String {
        // .docx is a ZIP containing XML files. The main content is in word/document.xml
        let fileURL = URL(fileURLWithPath: filePath)
        let tmpExtract = tmpDir.appendingPathComponent("docx_extract")
        let fm = FileManager.default
        try? fm.removeItem(at: tmpExtract)
        try fm.createDirectory(at: tmpExtract, withIntermediateDirectories: true)

        // Unzip
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", fileURL.path, "-d", tmpExtract.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()

        let docXML = tmpExtract.appendingPathComponent("word/document.xml")
        guard fm.fileExists(atPath: docXML.path) else {
            throw FileTranscriptionError.unsupportedFormat
        }

        let xmlData = try Data(contentsOf: docXML)
        let parser = DocxXMLParser()
        let xmlParser = XMLParser(data: xmlData)
        xmlParser.delegate = parser
        xmlParser.parse()

        try? fm.removeItem(at: tmpExtract)

        Log.write("DOCX extracted: \(parser.text.count) chars")
        guard !parser.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FileTranscriptionError.apiError("DOCX contains no text")
        }
        return parser.text
    }

    // MARK: - FFmpeg extract & compress

    private func extractAndCompress(filePath: String) throws -> URL {
        let inputURL = URL(fileURLWithPath: filePath)
        let ext = inputURL.pathExtension.lowercased()
        let isVideo = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "flv"].contains(ext)
        let compressedPath = tmpDir.appendingPathComponent("compressed.mp3")
        try? FileManager.default.removeItem(at: compressedPath)

        var args = ["-i", filePath]
        if isVideo { args += ["-vn"] }
        args += ["-ac", "1", "-ar", "16000", "-b:a", "48k", "-y", compressedPath.path]

        let ffmpeg = Process()
        guard let ffmpegPath = findFFmpeg() else { throw FileTranscriptionError.ffmpegFailed }
        ffmpeg.executableURL = URL(fileURLWithPath: ffmpegPath)
        ffmpeg.arguments = args
        ffmpeg.standardOutput = FileHandle.nullDevice
        ffmpeg.standardError = FileHandle.nullDevice
        try ffmpeg.run()
        ffmpeg.waitUntilExit()

        guard ffmpeg.terminationStatus == 0 else { throw FileTranscriptionError.ffmpegFailed }
        return compressedPath
    }

    // MARK: - Groq API transcription

    private func transcribeGroq(data: Data, fileName: String, apiKey: String) async throws -> String {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mpeg\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\ntext\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FileTranscriptionError.apiError(String(data: responseData, encoding: .utf8) ?? "Unknown")
        }
        return String(data: responseData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func transcribeGroqChunked(inputPath: String, apiKey: String) async throws -> String {
        let chunks = try splitAudio(inputPath: inputPath)
        Log.write("Split into \(chunks.count) chunks")

        var fullTranscript = ""
        for (i, chunkPath) in chunks.enumerated() {
            Log.write("Chunk \(i + 1)/\(chunks.count)...")
            let data = try Data(contentsOf: URL(fileURLWithPath: chunkPath))
            let text = try await transcribeGroq(data: data, fileName: "chunk_\(i).mp3", apiKey: apiKey)
            fullTranscript += (fullTranscript.isEmpty ? "" : " ") + text
        }
        return fullTranscript
    }

    // MARK: - Local whisper transcription (via Python mlx-whisper)

    private func transcribeLocal(audioPath: String) async throws -> String {
        Log.write("Local transcription: \(audioPath)")

        // Use Python mlx-whisper as subprocess
        let pythonScript = """
        import mlx_whisper, sys, json
        result = mlx_whisper.transcribe(sys.argv[1], path_or_hf_repo="mlx-community/whisper-large-v3-turbo")
        print(result.get("text", ""))
        """

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                let pipe = Pipe()

                // Try to find python with mlx_whisper
                let pythonPaths = [
                    "/opt/homebrew/bin/python3",
                    "/opt/homebrew/bin/python3.11",
                    "/usr/local/bin/python3",
                    "/usr/bin/python3",
                ]

                // Also check the venv we created earlier
                let venvPython = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Documents/Projekte/OpenWhispr/venv/bin/python3"
                let allPaths = [venvPython] + pythonPaths

                guard let pythonPath = allPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                    continuation.resume(throwing: FileTranscriptionError.noApiKey("Python not found for local transcription"))
                    return
                }

                process.executableURL = URL(fileURLWithPath: pythonPath)
                process.arguments = ["-c", pythonScript, audioPath]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    Log.write("Local transcription done: \(text.prefix(100))...")
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Split audio

    private func findFFprobe() -> String? {
        let paths = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe",
            "/opt/local/bin/ffprobe",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func splitAudio(inputPath: String) throws -> [String] {
        guard let ffprobePath = findFFprobe() else { throw FileTranscriptionError.ffmpegFailed }
        guard let ffmpegPath = findFFmpeg() else { throw FileTranscriptionError.ffmpegFailed }

        let probe = Process()
        let pipe = Pipe()
        probe.executableURL = URL(fileURLWithPath: ffprobePath)
        probe.arguments = ["-v", "quiet", "-show_entries", "format=duration", "-of", "csv=p=0", inputPath]
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        probe.waitUntilExit()

        let durationStr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        let totalDuration = Double(durationStr) ?? 0
        let chunkDuration = 300.0
        let chunkCount = Int(ceil(totalDuration / chunkDuration))

        var paths: [String] = []
        for i in 0..<chunkCount {
            let chunkPath = tmpDir.appendingPathComponent("chunk_\(i).mp3").path
            let split = Process()
            split.executableURL = URL(fileURLWithPath: ffmpegPath)
            split.arguments = ["-i", inputPath, "-ss", "\(Int(Double(i) * chunkDuration))", "-t", "\(Int(chunkDuration))", "-c", "copy", "-y", chunkPath]
            split.standardOutput = FileHandle.nullDevice
            split.standardError = FileHandle.nullDevice
            try split.run()
            split.waitUntilExit()
            if FileManager.default.fileExists(atPath: chunkPath) { paths.append(chunkPath) }
        }
        return paths
    }

    // MARK: - Claude summarization (respects provider setting)

    func summarize(transcript: String) async throws -> String {
        let provider = AppSettings.shared.polishProvider
        if provider == "ollama" {
            return try await summarizeOllama(transcript: transcript)
        }
        return try await summarizeClaude(transcript: transcript)
    }

    private func summarizeClaude(transcript: String) async throws -> String {
        let apiKey = AppSettings.shared.anthropicApiKey
        guard !apiKey.isEmpty else { return "" }

        let model = AppSettings.shared.searchModel
        let body: [String: Any] = [
            "model": model, "max_tokens": 2048,
            "system": "Summarize concisely. Same language. Key points, decisions, action items.",
            "messages": [["role": "user", "content": transcript]]
        ]

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
        else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func summarizeOllama(transcript: String) async throws -> String {
        let url = URL(string: "http://localhost:11434/api/chat")!
        let body: [String: Any] = [
            "model": "qwen2.5:3b",
            "messages": [
                ["role": "system", "content": "Summarize concisely. Same language. Key points, decisions, action items."],
                ["role": "user", "content": transcript]
            ],
            "stream": false
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let text = message["content"] as? String
        else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Ask question (respects provider)

    func askQuestion(transcript: String, question: String) async throws -> String {
        let provider = AppSettings.shared.polishProvider
        if provider == "ollama" {
            return try await askOllama(transcript: transcript, question: question)
        }
        return try await askClaude(transcript: transcript, question: question)
    }

    private func askClaude(transcript: String, question: String) async throws -> String {
        let apiKey = AppSettings.shared.anthropicApiKey
        guard !apiKey.isEmpty else { return "No API key" }

        let model = AppSettings.shared.searchModel
        let body: [String: Any] = [
            "model": model, "max_tokens": 2048,
            "system": "Answer based on transcript. Precise. Same language as question.",
            "messages": [["role": "user", "content": "Transcript:\n\(transcript)\n\nQuestion: \(question)"]]
        ]

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
        else { return "Parse error" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func askOllama(transcript: String, question: String) async throws -> String {
        let url = URL(string: "http://localhost:11434/api/chat")!
        let body: [String: Any] = [
            "model": "qwen2.5:3b",
            "messages": [
                ["role": "system", "content": "Answer based on transcript. Precise. Same language as question."],
                ["role": "user", "content": "Transcript:\n\(transcript)\n\nQuestion: \(question)"]
            ],
            "stream": false
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let text = message["content"] as? String
        else { return "Parse error" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Save transcript

    func saveTranscript(filePath: String, transcript: String) {
        let url = URL(fileURLWithPath: filePath)
        let txtPath = url.deletingPathExtension().appendingPathExtension("txt")
        try? transcript.write(to: txtPath, atomically: true, encoding: .utf8)
        Log.write("Saved: \(txtPath.path)")
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: tmpDir)
    }
}

enum FileTranscriptionError: LocalizedError {
    case noApiKey(String)
    case apiError(String)
    case ffmpegFailed
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .noApiKey(let msg): return msg
        case .apiError(let msg): return "API: \(msg)"
        case .ffmpegFailed: return "ffmpeg not found. Open Terminal and run: brew install ffmpeg"
        case .unsupportedFormat: return "Unsupported format"
        }
    }
}

// MARK: - DOCX XML Parser

/// Extracts text content from word/document.xml (OOXML format)
private class DocxXMLParser: NSObject, XMLParserDelegate {
    var text = ""
    private var inTextElement = false
    private var inParagraph = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        // w:t = text run, w:p = paragraph
        if elementName == "w:t" { inTextElement = true }
        if elementName == "w:p" { inParagraph = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTextElement { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "w:t" { inTextElement = false }
        if elementName == "w:p" {
            inParagraph = false
            text += "\n"
        }
    }
}
