import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var modeManager = PolishModeManager.shared
    @State private var selectedTab = "general"
    @State private var showNewScenario = false
    @State private var newScenarioName = ""
    @State private var newScenarioPrompt = ""
    @State private var editingPromptFor: PolishMode?
    @State private var isCapturingHotkey = false
    @State private var hotkeyDisplay = "Control"
    @State private var autoStartEnabled = LoginItemManager.isEnabled

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab.tabItem { Label("General", systemImage: "gear") }.tag("general")
            apiKeysTab.tabItem { Label("API Keys", systemImage: "key") }.tag("keys")
            modesTab.tabItem { Label("Modes", systemImage: "sparkles") }.tag("modes")
            licenseTab.tabItem { Label("License", systemImage: "lock.shield") }.tag("license")
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }.tag("about")
        }
        .frame(width: 540, height: 460)
        .sheet(isPresented: $showNewScenario) { newScenarioSheet }
        .sheet(item: $editingPromptFor) { mode in editPromptSheet(mode: mode) }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Speech Recognition") {
                Picker("Engine", selection: $settings.sttProvider) {
                    Text("☁️ Groq (fast, recommended)").tag("groq")
                    Text("💻 Local Whisper (offline)").tag("local")
                }
                Picker("Language", selection: $settings.language) {
                    ForEach(AppSettings.languages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
            }

            Section("Text Polishing") {
                Picker("Engine", selection: $settings.polishProvider) {
                    Text("☁️ Anthropic Claude (recommended)").tag("anthropic")
                    Text("💻 Ollama (local)").tag("ollama")
                }
            }

            Section("Voice Search") {
                Picker("AI Model", selection: $settings.searchModel) {
                    Text("Claude Opus 4.6 (best, slower)").tag("claude-opus-4-6")
                    Text("Claude Sonnet 4.5 (fast, recommended)").tag("claude-sonnet-4-6")
                    Text("Claude Haiku 4.5 (fastest, cheapest)").tag("claude-haiku-4-5-20251001")
                }
                Picker("Response Depth", selection: $settings.searchDepth) {
                    Text("🗿 Minimal — 1-2 sentences").tag("minimal")
                    Text("📝 Balanced — concise answer").tag("balanced")
                    Text("📚 Detailed — comprehensive").tag("detailed")
                }
            }

            Section("Microphone") {
                Picker("Device", selection: $settings.selectedMicDevice) {
                    Text("System Default").tag("")
                    ForEach(AudioDeviceList.shared.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
            }

            Section("Cassette Overlay") {
                HStack {
                    Text("👻")
                    Slider(value: $settings.cassetteOpacity, in: 0.1...1.0, step: 0.1)
                    Text("🎙")
                }
                Text("Opacity: \(Int(settings.cassetteOpacity * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Hotkey") {
                HStack {
                    Text("Current:")
                    Text(hotkeyDisplay)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Button(isCapturingHotkey ? "Press any key..." : "Change") {
                        isCapturingHotkey = true
                        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
                            guard self.isCapturingHotkey else { return event }
                            let keyName: String?
                            if event.type == .flagsChanged {
                                if event.modifierFlags.contains(.control) { keyName = "Control" }
                                else if event.modifierFlags.contains(.option) { keyName = "Option" }
                                else { return event }
                            } else {
                                switch event.keyCode {
                                case 0x60: keyName = "F5"; case 0x61: keyName = "F6"
                                case 0x64: keyName = "F8"; case 0x65: keyName = "F9"
                                case 0x6D: keyName = "F10"; case 0x67: keyName = "F11"
                                default: keyName = event.charactersIgnoringModifiers?.uppercased()
                                }
                            }
                            if let name = keyName {
                                self.hotkeyDisplay = name
                                self.settings.hotkeyCode = Int(event.keyCode)
                                self.isCapturingHotkey = false
                            }
                            return nil
                        }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dictation").font(.caption.bold())
                    Label("**Hold Ctrl** → record → release → paste", systemImage: "hand.tap")
                    Label("**Hold Ctrl+Shift** → hands-free dictation", systemImage: "hand.tap.fill")

                    Divider().padding(.vertical, 4)

                    Text("Voice Search").font(.caption.bold())
                    Label("**Double-tap Ctrl** → ask anything → tap Ctrl to stop", systemImage: "magnifyingglass")
                    Text("Requires Brave Search API key (free)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .font(.caption).foregroundStyle(.secondary)
                Text("Restart app after changing dictation hotkey.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Section("System") {
                Toggle("Start at login", isOn: $autoStartEnabled)
                    .onChange(of: autoStartEnabled) { _, newValue in
                        LoginItemManager.setEnabled(newValue)
                    }

                // Permissions
                HStack {
                    Label(PermissionManager.accessibilityGranted ? "Accessibility ✅" : "Accessibility ❌",
                          systemImage: "hand.raised")
                    Spacer()
                    if !PermissionManager.accessibilityGranted {
                        Button("Grant") { PermissionManager.openAccessibilitySettings() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
                HStack {
                    Label(PermissionManager.micPermissionGranted ? "Microphone ✅" : "Microphone ❌",
                          systemImage: "mic")
                    Spacer()
                    if !PermissionManager.micPermissionGranted {
                        Button("Grant") { PermissionManager.openMicSettings() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - API Keys

    private var apiKeysTab: some View {
        Form {
            Section {
                SecureField("Groq API Key", text: $settings.groqApiKey)
                    .textFieldStyle(.roundedBorder)
                Link("Get free key at console.groq.com →",
                     destination: URL(string: "https://console.groq.com/keys")!)
                    .font(.caption)
            } header: {
                Text("Groq (Speech Recognition)")
            } footer: {
                Text("Free. Groq runs Whisper large-v3 for fast, accurate transcription.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                SecureField("Anthropic API Key", text: $settings.anthropicApiKey)
                    .textFieldStyle(.roundedBorder)
                Link("Get key at console.anthropic.com →",
                     destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.caption)
            } header: {
                Text("Anthropic (Text Polishing)")
            } footer: {
                Text("Claude Haiku — fast and cheap (~$0.001/dictation).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                SecureField("Brave Search API Key", text: $settings.braveApiKey)
                    .textFieldStyle(.roundedBorder)
                Link("Get free key at brave.com/search/api →",
                     destination: URL(string: "https://brave.com/search/api/")!)
                    .font(.caption)
            } header: {
                Text("Brave Search (Voice Search)")
            } footer: {
                Text("Free tier: 2000 searches/month. Hold Ctrl+Cmd to ask anything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Modes

    private var modesTab: some View {
        Form {
            Section("Built-in Modes") {
                ForEach(PolishMode.builtIn) { mode in
                    HStack {
                        Text("\(mode.emoji) \(mode.label)")
                        Spacer()
                        if settings.activePolishMode == mode.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { settings.activePolishMode = mode.id }
                }
            }

            Section("Custom Scenarios") {
                if modeManager.customModes.isEmpty {
                    Text("No custom scenarios yet").foregroundStyle(.secondary).italic()
                } else {
                    ForEach(modeManager.customModes) { mode in
                        HStack {
                            Text("⭐ \(mode.label)")
                            Spacer()
                            Button { editingPromptFor = mode } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                            Button { modeManager.remove(id: mode.id) } label: { Image(systemName: "trash").foregroundStyle(.red) }.buttonStyle(.borderless)
                            if settings.activePolishMode == mode.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { settings.activePolishMode = mode.id }
                    }
                }
                Button { showNewScenario = true } label: { Label("New Scenario", systemImage: "plus") }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - License

    @State private var licenseInput = ""

    private var licenseTab: some View {
        Form {
            Section {
                if LicenseManager.isLicensed {
                    HStack {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.title2)
                        VStack(alignment: .leading) {
                            Text("Licensed").font(.headline)
                            Text("Lifetime access activated").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "clock.fill").foregroundStyle(.orange).font(.title2)
                        VStack(alignment: .leading) {
                            Text("Free Trial").font(.headline)
                            Text("\(settings.remainingTrial) of \(AppSettings.trialLimit) uses remaining")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Enter License Key") {
                TextField("TIC-XXXXX-XXXXX-XXXXX-XXXXX", text: $licenseInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button("Activate") {
                    if LicenseManager.validate(licenseInput.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        settings.licenseKey = licenseInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        licenseInput = ""
                    }
                }
                .disabled(licenseInput.isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("TalkIsCheap")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Version 2.0.0")
                .font(.caption).foregroundStyle(.secondary)
            Text("Voice-to-text dictation for macOS")
                .foregroundStyle(.secondary)

            Divider().frame(width: 200)

            VStack(spacing: 4) {
                Text("Hold a key, speak, release.").font(.caption)
                Text("Your words — polished and pasted.").font(.caption)
            }
            .foregroundStyle(.tertiary)

            Spacer()

            Text("© 2026 TalkIsCheap")
                .font(.caption2).foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sheets

    private var newScenarioSheet: some View {
        VStack(spacing: 16) {
            Text("New Polishing Scenario").font(.headline)
            TextField("Name (e.g. LinkedIn Post)", text: $newScenarioName).textFieldStyle(.roundedBorder)
            Text("System Prompt").font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            TextEditor(text: $newScenarioPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(height: 150)
                .border(Color.secondary.opacity(0.3))
            Text("Tells the AI how to process your text.\nExample: \"Rewrite as a LinkedIn post. Under 200 words.\"")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { showNewScenario = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") {
                    modeManager.add(label: newScenarioName, emoji: "⭐", prompt: newScenarioPrompt)
                    settings.activePolishMode = modeManager.customModes.last?.id ?? "clean"
                    newScenarioName = ""; newScenarioPrompt = ""
                    showNewScenario = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newScenarioName.isEmpty || newScenarioPrompt.isEmpty)
            }
        }
        .padding(20).frame(width: 450)
    }

    private func editPromptSheet(mode: PolishMode) -> some View {
        EditPromptView(mode: mode) { editingPromptFor = nil }
    }
}

struct EditPromptView: View {
    let mode: PolishMode
    let onDismiss: () -> Void
    @State private var prompt = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit: \(mode.label)").font(.headline)
            TextEditor(text: $prompt)
                .font(.system(.body, design: .monospaced))
                .frame(height: 200)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Button("Cancel") { onDismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { PolishModeManager.shared.updatePrompt(id: mode.id, prompt: prompt); onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 450)
        .onAppear { prompt = mode.prompt ?? "" }
    }
}

/// Audio device list for mic picker
final class AudioDeviceList: ObservableObject {
    static let shared = AudioDeviceList()
    struct Device: Identifiable { let id: String; let name: String }
    @Published var devices: [Device] = []

    init() { refresh() }

    func refresh() {
        // Simple approach using AVCaptureDevice
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        devices = discoverySession.devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }
}

import AVFoundation
