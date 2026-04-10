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

        // Permissions
        let accessibility = AXIsProcessTrusted()
        let mic = PermissionManager.micPermissionGranted
        Log.write("Accessibility: \(accessibility), Mic: \(mic)")

        if !accessibility { PermissionManager.requestAccessibility() }
        if !mic {
            PermissionManager.requestMicPermission { granted in
                Log.write("Mic permission: \(granted)")
            }
        }

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

        if !AppSettings.shared.hasCompletedOnboarding {
            AppState.shared.showOnboarding = true
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
