import Foundation
import AppKit

/// Handles automatic installation of local mode dependencies (mlx-whisper, Ollama, models)
@MainActor
final class LocalSetupService: ObservableObject {
    static let shared = LocalSetupService()

    enum SetupStep: String {
        case checkingPython = "Checking Python installation..."
        case installingVenv = "Creating Python environment..."
        case installingWhisper = "Installing speech recognition packages..."
        case downloadingWhisperModel = "Downloading Whisper model (~1.6 GB)..."
        case checkingOllama = "Checking Ollama installation..."
        case installingOllama = "Installing Ollama..."
        case startingOllama = "Starting Ollama..."
        case pullingModel = "Downloading language model (~1.9 GB)..."
        case done = "Setup complete!"
    }

    enum SetupState: Equatable {
        case idle
        case installing(step: String)
        case done
        case error(String)
    }

    @Published var state: SetupState = .idle

    private let appSupportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TalkIsCheap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var venvPythonPath: String {
        appSupportDir.appendingPathComponent("venv/bin/python3").path
    }

    var venvDir: URL {
        appSupportDir.appendingPathComponent("venv")
    }

    // MARK: - Checks

    func findPython() -> String? {
        let paths = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    func isVenvReady() -> Bool {
        FileManager.default.isExecutableFile(atPath: venvPythonPath)
    }

    func isWhisperInstalled() -> Bool {
        guard isVenvReady() else { return false }
        let result = runProcess(venvPythonPath, arguments: ["-c", "import mlx_whisper; print('ok')"])
        return result.contains("ok")
    }

    func isOllamaInstalled() -> Bool {
        let paths = [
            "/usr/local/bin/ollama",
            "/opt/homebrew/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
        ]
        return paths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func findOllama() -> String? {
        let paths = [
            "/usr/local/bin/ollama",
            "/opt/homebrew/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func isOllamaRunning() async -> Bool {
        do {
            let (_, response) = try await URLSession.shared.data(from: URL(string: "http://localhost:11434/api/tags")!)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func isModelPulled(model: String = "qwen2.5:3b") async -> Bool {
        do {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://localhost:11434/api/tags")!)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let models = json?["models"] as? [[String: Any]] ?? []
            return models.contains { ($0["name"] as? String)?.hasPrefix(model) == true }
        } catch {
            return false
        }
    }

    // MARK: - Full Setup

    /// Runs the complete local setup. Call from onboarding when user picks local mode.
    func setupLocalMode(needsSTT: Bool, needsPolish: Bool) async {
        state = .installing(step: SetupStep.checkingPython.rawValue)
        Log.write("LocalSetup: starting (stt=\(needsSTT), polish=\(needsPolish))")

        do {
            // STT: Python + mlx-whisper
            if needsSTT {
                try await setupWhisper()
            }

            // Polish: Ollama
            if needsPolish {
                try await setupOllama()
            }

            state = .done
            Log.write("LocalSetup: complete!")

        } catch {
            state = .error(error.localizedDescription)
            Log.write("LocalSetup: FAILED — \(error)")
        }
    }

    // MARK: - Whisper Setup

    private func setupWhisper() async throws {
        // 1. Check Python
        state = .installing(step: SetupStep.checkingPython.rawValue)
        guard let systemPython = findPython() else {
            throw SetupError.pythonNotFound
        }
        Log.write("LocalSetup: Python found at \(systemPython)")

        // 2. Create venv
        if !isVenvReady() {
            state = .installing(step: SetupStep.installingVenv.rawValue)
            Log.write("LocalSetup: Creating venv at \(venvDir.path)")
            let result = runProcess(systemPython, arguments: ["-m", "venv", venvDir.path])
            Log.write("LocalSetup: venv result: \(result)")

            guard isVenvReady() else {
                throw SetupError.venvFailed
            }
        }

        // 3. Install packages
        if !isWhisperInstalled() {
            state = .installing(step: SetupStep.installingWhisper.rawValue)
            Log.write("LocalSetup: Installing mlx-whisper packages...")
            let pip = appSupportDir.appendingPathComponent("venv/bin/pip3").path
            let result = runProcess(pip, arguments: ["install", "mlx-whisper", "soundfile", "numpy"])
            Log.write("LocalSetup: pip install result: \(result.suffix(200))")

            guard isWhisperInstalled() else {
                throw SetupError.whisperInstallFailed
            }
        }

        // 4. Pre-download Whisper model (first transcription downloads it)
        state = .installing(step: SetupStep.downloadingWhisperModel.rawValue)
        Log.write("LocalSetup: Pre-downloading Whisper model...")
        let script = """
        import mlx_whisper
        import numpy as np
        import tempfile, soundfile as sf
        silence = np.zeros(16000, dtype=np.float32)
        with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f:
            sf.write(f.name, silence, 16000)
            mlx_whisper.transcribe(f.name, path_or_hf_repo='mlx-community/whisper-large-v3-turbo', language='en')
        print('MODEL_OK')
        """
        let modelResult = runProcess(venvPythonPath, arguments: ["-c", script], timeout: 600)
        if !modelResult.contains("MODEL_OK") {
            Log.write("LocalSetup: Whisper model download may have failed: \(modelResult.suffix(200))")
            // Don't throw — model will download on first use
        }
        Log.write("LocalSetup: Whisper model ready")
    }

    // MARK: - Ollama Setup

    private func setupOllama() async throws {
        // 1. Check if Ollama is installed
        state = .installing(step: SetupStep.checkingOllama.rawValue)

        if !isOllamaInstalled() {
            state = .installing(step: SetupStep.installingOllama.rawValue)
            Log.write("LocalSetup: Installing Ollama...")
            try await installOllama()
        }

        // 2. Start Ollama if not running
        if !(await isOllamaRunning()) {
            state = .installing(step: SetupStep.startingOllama.rawValue)
            Log.write("LocalSetup: Starting Ollama...")
            startOllamaDaemon()
            // Wait for it to be ready
            for _ in 0..<30 {
                try await Task.sleep(for: .seconds(1))
                if await isOllamaRunning() { break }
            }
            guard await isOllamaRunning() else {
                throw SetupError.ollamaStartFailed
            }
        }

        // 3. Pull model
        if !(await isModelPulled()) {
            state = .installing(step: SetupStep.pullingModel.rawValue)
            Log.write("LocalSetup: Pulling qwen2.5:3b model...")
            try await pullModel()
        }

        Log.write("LocalSetup: Ollama ready")
    }

    private func installOllama() async throws {
        // Download Ollama installer
        let downloadURL = URL(string: "https://ollama.com/download/Ollama-darwin.zip")!
        let tmpZip = FileManager.default.temporaryDirectory.appendingPathComponent("Ollama-darwin.zip")
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ollama-install")

        // Download
        let (data, response) = try await URLSession.shared.data(from: downloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SetupError.ollamaDownloadFailed
        }
        try data.write(to: tmpZip)

        // Unzip
        try? FileManager.default.removeItem(at: tmpDir)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        _ = runProcess("/usr/bin/ditto", arguments: ["-xk", tmpZip.path, tmpDir.path])

        // Move to Applications
        let ollamaApp = tmpDir.appendingPathComponent("Ollama.app")
        let destApp = URL(fileURLWithPath: "/Applications/Ollama.app")
        try? FileManager.default.removeItem(at: destApp)

        if FileManager.default.fileExists(atPath: ollamaApp.path) {
            try FileManager.default.moveItem(at: ollamaApp, to: destApp)
            Log.write("LocalSetup: Ollama installed to /Applications")
        } else {
            throw SetupError.ollamaInstallFailed
        }

        // Cleanup
        try? FileManager.default.removeItem(at: tmpZip)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func startOllamaDaemon() {
        if let ollamaPath = findOllama() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ollamaPath)
            process.arguments = ["serve"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            Log.write("LocalSetup: ollama serve started")
        } else {
            // Try launching the app
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Ollama.app"))
            Log.write("LocalSetup: Ollama.app launched")
        }
    }

    private func pullModel(model: String = "qwen2.5:3b") async throws {
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/pull")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": model])
        request.timeoutInterval = 600 // 10 min for large model download

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SetupError.modelPullFailed(body)
        }
        Log.write("LocalSetup: Model \(model) pulled successfully")
    }

    // MARK: - Helpers

    private func runProcess(_ path: String, arguments: [String], timeout: TimeInterval = 120) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            // Wait with timeout
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
            }
            if process.isRunning { process.terminate() }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Errors

    enum SetupError: LocalizedError {
        case pythonNotFound
        case venvFailed
        case whisperInstallFailed
        case ollamaDownloadFailed
        case ollamaInstallFailed
        case ollamaStartFailed
        case modelPullFailed(String)

        var errorDescription: String? {
            switch self {
            case .pythonNotFound:
                return "Python 3 not found. Install it from python.org or run: brew install python3"
            case .venvFailed:
                return "Failed to create Python virtual environment"
            case .whisperInstallFailed:
                return "Failed to install speech recognition packages"
            case .ollamaDownloadFailed:
                return "Failed to download Ollama"
            case .ollamaInstallFailed:
                return "Failed to install Ollama"
            case .ollamaStartFailed:
                return "Failed to start Ollama. Please start it manually."
            case .modelPullFailed(let msg):
                return "Failed to download language model: \(msg)"
            }
        }
    }
}
