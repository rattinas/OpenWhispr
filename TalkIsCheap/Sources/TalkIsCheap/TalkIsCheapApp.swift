import SwiftUI
import Cocoa

@main
struct TalkIsCheapApp: App {
    @StateObject private var state = AppState.shared
    @StateObject private var startup = StartupManager.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            MenuBarIcon(state: state)
        }
        .menuBarExtraStyle(.window)

        Window("TalkIsCheap Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("TalkIsCheap Setup", id: "onboarding") {
            OnboardingView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Transcription History", id: "history") {
            HistoryView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

@MainActor
final class StartupManager: ObservableObject {
    static let shared = StartupManager()

    init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.performStartup()
        }
    }

    private func performStartup() {
        Log.write("=== STARTUP v2.0 ===")

        // Permissions — only log status, don't prompt on every launch
        // (permissions are requested during onboarding, not on startup)
        let accessibility = AXIsProcessTrusted()
        let mic = PermissionManager.micPermissionGranted
        Log.write("Accessibility: \(accessibility), Mic: \(mic)")

        // Hotkey
        let hotkey = HotkeyManager.shared
        hotkey.onKeyDown = {
            Log.write("KEY DOWN")
            Task { @MainActor in AppState.shared.startRecording() }
        }
        hotkey.onKeyUp = {
            Log.write("KEY UP")
            Task { @MainActor in
                if AppState.shared.recorder.isRecording { AppState.shared.stopAndProcess() }
            }
        }
        hotkey.onCancel = {
            Log.write("KEY CANCEL (short tap)")
            Task { @MainActor in AppState.shared.cancelRecording() }
        }
        hotkey.onSearchKeyDown = {
            Log.write("SEARCH KEY DOWN")
            Task { @MainActor in AppState.shared.startSearchRecording() }
        }
        hotkey.onSearchKeyUp = {
            Log.write("SEARCH KEY UP")
            Task { @MainActor in
                if AppState.shared.recorder.isRecording { AppState.shared.stopSearchAndProcess() }
            }
        }
        hotkey.start()

        // Install Finder Quick Actions
        QuickActionInstaller.installIfNeeded()

        // Register URL scheme handler
        setupURLHandler()

        AppState.shared.status = .ready
        Log.write("Ready!")

        UpdateChecker.shared.checkForUpdate()
        checkLicenseValidation()

        // Auto-start Ollama if local polish mode is selected
        if AppSettings.shared.polishProvider == "ollama" {
            Task {
                if !(await LocalSetupService.shared.isOllamaRunning()) {
                    Log.write("Auto-starting Ollama...")
                    LocalSetupService.shared.startOllamaDaemon()
                }
            }
        }

        if !AppSettings.shared.hasCompletedOnboarding {
            showOnboardingPanel()
        }

        // Listen for paywall show requests
        NotificationCenter.default.addObserver(
            forName: .showPaywall,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showPaywallPanel()
        }
    }

    private var paywallPanel: NSPanel?

    private func showPaywallPanel() {
        if paywallPanel?.isVisible == true {
            paywallPanel?.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        panel.title = "TalkIsCheap"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: PaywallView())
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        paywallPanel = panel
        Log.write("Paywall shown")
    }

    private var onboardingPanel: NSPanel?
    private var onboardingDelegate: OnboardingWindowDelegate?

    private func showOnboardingPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        panel.title = "TalkIsCheap Setup"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: OnboardingView())
        panel.center()

        // Mark onboarding complete if user closes panel via X button
        let delegate = OnboardingWindowDelegate()
        panel.delegate = delegate
        onboardingDelegate = delegate

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingPanel = panel
        Log.write("Onboarding panel shown")
    }

    private func checkLicenseValidation() {
        guard LicenseManager.isLicensed else { return }

        let lastCheck = AppSettings.shared.lastValidationCheck
        let now = Date().timeIntervalSince1970
        let sevenDays: Double = 7 * 86400

        guard now - lastCheck > sevenDays else { return }

        Task {
            let valid = await LicenseManager.validateOnline()
            if let valid {
                if valid {
                    AppSettings.shared.lastValidationCheck = now
                    Log.write("License validation: OK")
                } else {
                    Log.write("License validation: INVALID — clearing activation")
                    AppSettings.shared.activationToken = ""
                    AppSettings.shared.activatedAt = ""
                }
            } else {
                Log.write("License validation: network unreachable, skipping")
            }
        }
    }

    private func setupURLHandler() {
        // Handle talkischeap:// URLs
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        Log.write("URL handler registered")
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString)
        else { return }

        Log.write("URL received: \(urlString)")
        let host = url.host ?? ""

        // New approach: read file path from temp file (avoids URL-encoding issues)
        if host.contains("file") {
            let tmpPath = "/tmp/.talkischeap_path"
            guard let filePath = try? String(contentsOfFile: tmpPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  !filePath.isEmpty else {
                Log.write("No path in temp file")
                return
            }
            try? FileManager.default.removeItem(atPath: tmpPath)
            Log.write("File path from temp: \(filePath)")

            Task { @MainActor in
                FileTranscriptionManager.shared.processFile(path: filePath)
            }
            return
        }

        // Legacy: URL query parameter approach
        let path = url.queryItems?["path"] ?? ""
        guard !path.isEmpty else {
            Log.write("No path in URL")
            return
        }
        let decodedPath = path.removingPercentEncoding ?? path

        Task { @MainActor in
            switch host {
            case "transcribe", "transcribe-summarize":
                FileTranscriptionManager.shared.processFile(path: decodedPath)
            default:
                Log.write("Unknown URL action: \(host)")
            }
        }
    }
}

// Helper to parse query params
extension URL {
    var queryItems: [String: String]? {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else { return nil }
        return Dictionary(uniqueKeysWithValues: items.compactMap { item in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
    }
}

// Handles onboarding window close: marks onboarding complete if user closes via X
final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        AppSettings.shared.hasCompletedOnboarding = true
        Log.write("Onboarding window closed — marking complete")
    }
}
