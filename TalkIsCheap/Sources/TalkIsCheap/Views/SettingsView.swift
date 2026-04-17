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
    @State private var showingFeedback = false

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab.tabItem { Label("General", systemImage: "gear") }.tag("general")
            if !settings.shouldUseProxy {
                apiKeysTab.tabItem { Label("API Keys", systemImage: "key") }.tag("keys")
            }
            DictionaryView().tabItem { Label("Dictionary", systemImage: "book") }.tag("dictionary")
            modesTab.tabItem { Label("Modes", systemImage: "sparkles") }.tag("modes")
            licenseTab.tabItem { Label("License", systemImage: "lock.shield") }.tag("license")
            updatesTab.tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }.tag("updates")
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }.tag("about")
        }
        .frame(width: 540, height: 460)
        .sheet(isPresented: $showNewScenario) { newScenarioSheet }
        .sheet(item: $editingPromptFor) { mode in editPromptSheet(mode: mode) }
        .sheet(isPresented: $showingFeedback) { FeedbackView() }
    }

    // MARK: - General

    private var serviceMode: Binding<String> {
        Binding(
            get: {
                if settings.useCloudProxy { return "cloud" }
                if settings.sttProvider == "local" { return "offline" }
                return "byok"
            },
            set: { newValue in
                switch newValue {
                case "cloud":
                    settings.useCloudProxy = true
                    settings.sttProvider = "groq"
                    settings.polishProvider = "anthropic"
                case "byok":
                    settings.useCloudProxy = false
                    settings.sttProvider = "groq"
                    settings.polishProvider = "anthropic"
                case "offline":
                    settings.useCloudProxy = false
                    settings.sttProvider = "local"
                    settings.polishProvider = "ollama"
                default: break
                }
            }
        )
    }

    @ObservedObject private var localSetup = LocalSetupService.shared

    @ViewBuilder
    private var offlineSetupRow: some View {
        let whisperReady = FileManager.default.isExecutableFile(atPath: localSetup.venvPythonPath)
        let isInstalling: Bool = {
            if case .installing = localSetup.state { return true }
            return false
        }()

        if whisperReady {
            Label("Offline models ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if case .installing(let step) = localSetup.state {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
                        Text(step).font(.caption).foregroundStyle(.secondary)
                    }
                } else if case .error(let msg) = localSetup.state {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                } else {
                    Text("Offline needs ~3.5 GB of local models. Installation takes 5-10 minutes.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Button {
                    Task {
                        await localSetup.setupLocalMode(
                            needsSTT: settings.sttProvider == "local",
                            needsPolish: settings.polishProvider == "ollama"
                        )
                    }
                } label: {
                    Label(isInstalling ? "Installing…" : "Install offline models",
                          systemImage: "arrow.down.circle")
                }
                .disabled(isInstalling)
            }
        }
    }

    private var generalTab: some View {
        Form {
            Section {
                Picker("Mode", selection: serviceMode) {
                    Text("☁️ Use our cloud — 10 free tries, then subscription").tag("cloud")
                    Text("🔑 My own API keys — free, unlimited").tag("byok")
                    Text("💻 Fully offline — local models, 100% private").tag("offline")
                }
                .pickerStyle(.inline)
                .labelsHidden()

                if settings.useCloudProxy && settings.tier == "trial" {
                    Label("\(settings.trialUsesRemaining) of 10 free uses left",
                          systemImage: "gift")
                        .foregroundStyle(.blue)
                        .font(.caption)
                }

                // Offline setup — show when user picks offline and venv/ollama are missing
                if !settings.useCloudProxy && settings.sttProvider == "local" {
                    offlineSetupRow
                }
            } header: {
                Text("Service")
            } footer: {
                Text("Switch anytime. Trial uses are only counted when the cloud mode is active.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Speech Recognition") {
                if !settings.useCloudProxy {
                    Picker("Engine", selection: $settings.sttProvider) {
                        Text("☁️ Groq (fast, recommended)").tag("groq")
                        Text("💻 Local Whisper (offline)").tag("local")
                    }
                }
                Picker("Language", selection: $settings.language) {
                    ForEach(AppSettings.languages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                if settings.useCloudProxy {
                    Text("Engine is managed by our cloud while you use the cloud plan. Switch to 'My own API keys' or 'Fully offline' above to change.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if !settings.useCloudProxy {
                Section("Text Polishing") {
                    Picker("Engine", selection: $settings.polishProvider) {
                        Text("☁️ Anthropic Claude (recommended)").tag("anthropic")
                        Text("💻 Ollama (local)").tag("ollama")
                    }
                }
            }

            Section("Voice Search") {
                Picker("AI Model", selection: $settings.searchModel) {
                    Text("Claude Opus 4.6 (best, slower)").tag("claude-opus-4-6")
                    Text("Claude Sonnet 4.6 (fast, recommended)").tag("claude-sonnet-4-6")
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
                    Label("**Hold** your hotkey → record → release → paste", systemImage: "hand.tap")
                    Label("**Hold** hotkey **+ Shift** → hands-free dictation", systemImage: "hand.tap.fill")

                    Divider().padding(.vertical, 4)

                    Text("Voice Search").font(.caption.bold())
                    Label("**Double-tap** your hotkey → ask anything", systemImage: "magnifyingglass")
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
                Text("Groq (Speech-to-Text)")
            } footer: {
                Text("Whisper large-v3-turbo — very fast and accurate. Free tier is generous.")
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
                Text("Free tier: 2000 searches/month. Double-tap your hotkey to ask anything.")
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
    @State private var isActivating = false
    @State private var activationMessage: (text: String, isError: Bool)?
    @State private var isDeactivating = false

    private var licenseTab: some View {
        Form {
            Section("Your Plan") {
                HStack(spacing: 12) {
                    Image(systemName: tierIcon).foregroundStyle(tierColor).font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.tierLabel).font(.headline)
                        Text(tierSubtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if settings.tier == "trial" {
                    ProgressView(value: Double(10 - settings.trialUsesRemaining), total: 10)
                        .tint(.orange)
                    Text("\(settings.trialUsesRemaining) free uses remaining")
                        .font(.caption).foregroundStyle(.secondary)

                    Button {
                        NotificationCenter.default.post(name: .showPaywall, object: nil)
                    } label: {
                        Label("Upgrade Now", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }

                if settings.tier == "pro_monthly" || settings.tier == "pro_annual" {
                    Button {
                        Task { await openStripePortal() }
                    } label: {
                        Label("Manage Subscription", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)

                    if !settings.currentPeriodEnd.isEmpty {
                        Text("Renews: \(formatDate(settings.currentPeriodEnd))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }

            Section {
                if LicenseManager.isLicensed && settings.tier == "lifetime" {
                    HStack {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.title2)
                        VStack(alignment: .leading) {
                            Text("Lifetime License Active").font(.headline)
                            Text("Activated on this Mac").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if LicenseManager.isLicensed {
                    HStack {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.title2)
                        VStack(alignment: .leading) {
                            Text("Licensed").font(.headline)
                            Text("Activated on this Mac").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if settings.remainingTrial > 0 {
                    HStack {
                        Image(systemName: "clock.fill").foregroundStyle(.orange).font(.title2)
                        VStack(alignment: .leading) {
                            Text("Free Trial").font(.headline)
                            Text("\(settings.remainingTrial) of \(AppSettings.trialLimit) uses remaining")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        HStack {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.title2)
                            VStack(alignment: .leading) {
                                Text("Trial Expired").font(.headline)
                                Text("Purchase a license to continue using TalkIsCheap")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            NotificationCenter.default.post(name: .showPaywall, object: nil)
                        } label: {
                            Label("See Pricing Options", systemImage: "sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                }
            }

            // Show activate-input whenever the user is not on a paid tier.
            // Trial users still have an activation token, but they need to be
            // able to enter a purchased key to upgrade. Only hide once they're
            // on lifetime / pro.
            let isPaidTier = settings.tier == "lifetime" || settings.tier == "pro_monthly" || settings.tier == "pro_annual"
            if !isPaidTier {
                Section {
                    TextField("TIC-XXXXX-XXXXX-XXXXX-XXXXX", text: $licenseInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .disabled(isActivating)

                    Button {
                        isActivating = true
                        activationMessage = nil
                        Task { @MainActor in
                            let result = await LicenseManager.activate(key: licenseInput)
                            isActivating = false
                            switch result {
                            case .success:
                                activationMessage = ("License activated!", false)
                                licenseInput = ""
                            case .alreadyActivated:
                                activationMessage = ("License re-activated!", false)
                                licenseInput = ""
                            case .invalidKey:
                                activationMessage = ("Invalid license key.", true)
                            case .maxReached(let msg):
                                activationMessage = (msg, true)
                            case .revoked:
                                activationMessage = ("This license has been revoked.", true)
                            case .networkError(let msg):
                                activationMessage = ("Connection error: \(msg)", true)
                            }
                        }
                    } label: {
                        HStack {
                            if isActivating {
                                ProgressView().scaleEffect(0.6)
                            }
                            Text(isActivating ? "Activating..." : "Activate")
                        }
                    }
                    .disabled(licenseInput.isEmpty || isActivating)

                    if let msg = activationMessage {
                        Text(msg.text)
                            .font(.caption)
                            .foregroundStyle(msg.isError ? .red : .green)
                    }
                } header: {
                    Text("Activate License")
                } footer: {
                    Text("Already bought? Enter your key here — it will replace your trial.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Manage License") {
                    HStack {
                        Text("Key")
                        Spacer()
                        Text(settings.licenseKey).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Machine ID")
                        Spacer()
                        Text(LicenseManager.hardwareUUID().prefix(8) + "...").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        isDeactivating = true
                        Task { @MainActor in
                            let success = await LicenseManager.deactivate()
                            isDeactivating = false
                            if !success {
                                activationMessage = ("Failed to deactivate. Check your internet connection.", true)
                            }
                        }
                    } label: {
                        HStack {
                            if isDeactivating {
                                ProgressView().scaleEffect(0.6)
                            }
                            Text(isDeactivating ? "Deactivating..." : "Deactivate this Mac")
                        }
                    }
                    .disabled(isDeactivating)

                    if let msg = activationMessage, msg.isError {
                        Text(msg.text).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Updates

    private var updatesTab: some View {
        Form {
            Section("Version") {
                HStack {
                    Text("Current version")
                    Spacer()
                    Text(UpdateManager.shared.currentVersion)
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section("Automatic Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { UpdateManager.shared.automaticChecks },
                    set: { UpdateManager.shared.automaticChecks = $0 }
                ))
                Text("Checks once per day. Updates are cryptographically signed — only genuine releases from us will install.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Check for Updates Now") {
                    UpdateManager.shared.checkForUpdates()
                }
                .disabled(!UpdateManager.shared.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About

    private var appVersionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    // MARK: - Subscription helpers

    private var tierIcon: String {
        switch settings.tier {
        case "trial": return "clock.fill"
        case "lifetime": return "infinity.circle.fill"
        case "pro_monthly", "pro_annual": return "star.circle.fill"
        case "canceled": return "xmark.circle.fill"
        default: return "questionmark.circle.fill"
        }
    }

    private var tierColor: Color {
        switch settings.tier {
        case "trial": return .orange
        case "lifetime": return Color(red: 0.91, green: 0.38, blue: 0.30)
        case "pro_monthly", "pro_annual": return .blue
        case "canceled": return .red
        default: return .gray
        }
    }

    private var tierSubtitle: String {
        switch settings.tier {
        case "trial": return "API keys included. Upgrade to keep going."
        case "lifetime": return "Unlimited. You provide API keys."
        case "pro_monthly": return "2000 dictations/mo, we provide API keys"
        case "pro_annual": return "2000 dictations/mo, annual billing"
        case "canceled": return "Subscription ended. Reactivate or switch to Lifetime."
        default: return "Not activated"
        }
    }

    private func formatDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return iso }
        let df = DateFormatter()
        df.dateStyle = .medium
        return df.string(from: date)
    }

    private func openStripePortal() async {
        guard var request = URLRequest(url: URL(string: "https://talkischeap.app/api/subscription/portal")!) as URLRequest? else { return }
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.activationToken)", forHTTPHeaderField: "Authorization")
        request.setValue(LicenseManager.hardwareUUID(), forHTTPHeaderField: "X-Hardware-Id")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let urlStr = json["url"] as? String,
               let url = URL(string: urlStr) {
                NSWorkspace.shared.open(url)
            }
        } catch {
            Log.write("Portal open failed: \(error)")
        }
    }

    private var aboutTab: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)

            Text("TalkIsCheap")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            Text("Version \(appVersionString)")
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("Voice-to-text dictation for macOS")
                .foregroundStyle(.secondary)

            Divider().frame(width: 200)

            VStack(spacing: 4) {
                Text("Hold a key, speak, release.").font(.caption)
                Text("Your words — polished and pasted.").font(.caption)
            }
            .foregroundStyle(.tertiary)

            Button {
                showingFeedback = true
            } label: {
                Label("Send Feedback", systemImage: "paperplane.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Spacer()

            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text("Built by Benedikt Rapp")
                    Text("·")
                    Text("Made in Switzerland 🇨🇭")
                }
                .font(.caption2).foregroundStyle(.secondary)

                Text("© 2026 TalkIsCheap")
                    .font(.caption2).foregroundStyle(.quaternary)
            }
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
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        devices = discoverySession.devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }
}

import AVFoundation
