import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var localSetup = LocalSetupService.shared
    @State private var step = 0
    @State private var micGranted = PermissionManager.micPermissionGranted
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @Environment(\.dismiss) private var dismiss

    private var needsLocalInstall: Bool {
        settings.sttProvider == "local" || settings.polishProvider == "ollama"
    }

    @State private var selectedPlan = "cloud" // "cloud", "byok", "offline"
    private let totalSteps = 9

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.1))
                    Rectangle().fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(step + 1) / CGFloat(totalSteps))
                        .animation(.easeInOut(duration: 0.3), value: step)
                }
            }
            .frame(height: 3)

            // Content
            Group {
                switch step {
                case 0: welcomeStep
                case 1: permissionsStep
                case 2: planStep
                case 3: apiKeysStep
                case 4: localInstallStep
                case 5: languageStep
                case 6: howToDictateStep
                case 7: polishModesStep
                case 8: readyStep
                default: readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .id(step)
        }
        .frame(width: 520, height: 520)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Spacer()

            // App icon from bundle
            if let iconImage = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                Image(nsImage: iconImage)
                    .resizable()
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .shadow(color: .black.opacity(0.2), radius: 10)
            }

            Text("TalkIsCheap")
                .font(.system(size: 32, weight: .bold, design: .rounded))

            Text("Your voice — polished and pasted.")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                featureBullet(icon: "keyboard", text: "Hold a key, speak, release")
                featureBullet(icon: "sparkles", text: "AI cleans up your text instantly")
                featureBullet(icon: "doc.on.clipboard", text: "Auto-pasted wherever your cursor is")
            }
            .padding(.top, 8)

            Text("10 free uses included. No credit card needed.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)

            Spacer()

            nextButton("Let's set up")
        }
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 16) {
            stepHeader(icon: "lock.shield", title: "Permissions", subtitle: "TalkIsCheap needs two permissions to work")

            Spacer()

            VStack(spacing: 16) {
                permissionCard(
                    icon: "mic.fill",
                    title: "Microphone Access",
                    desc: "To hear your voice when you dictate",
                    granted: micGranted,
                    action: {
                        PermissionManager.requestMicPermission { granted in
                            micGranted = granted
                        }
                        // Bring setup window back after System Settings opens (for denied case)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            NSApp.activate(ignoringOtherApps: true)
                            for window in NSApp.windows where window.title == "TalkIsCheap Setup" {
                                window.makeKeyAndOrderFront(nil)
                            }
                        }
                        // Poll for grant
                        var pollCount = 0
                        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                            pollCount += 1
                            if PermissionManager.micPermissionGranted {
                                micGranted = true
                                timer.invalidate()
                            } else if pollCount > 60 {
                                timer.invalidate()
                            }
                        }
                    }
                )

                permissionCard(
                    icon: "hand.raised.fill",
                    title: "Accessibility Access",
                    desc: "To paste text at your cursor position",
                    granted: accessibilityGranted,
                    action: {
                        // Open System Settings directly and bring to front
                        PermissionManager.openAccessibilitySettings()
                        // Brief delay then bring our window back to front
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            NSApp.activate(ignoringOtherApps: true)
                            // Find and raise our onboarding panel
                            for window in NSApp.windows where window.title == "TalkIsCheap Setup" {
                                window.makeKeyAndOrderFront(nil)
                            }
                        }
                        // Poll for grant
                        var pollCount = 0
                        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { timer in
                            pollCount += 1
                            if AXIsProcessTrusted() {
                                accessibilityGranted = true
                                timer.invalidate()
                            } else if pollCount > 60 {
                                timer.invalidate()
                            }
                        }
                    }
                )

                if !accessibilityGranted {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("How to grant Accessibility:").font(.caption.bold())
                        Text("1. System Settings opens → find TalkIsCheap in the list").font(.caption2)
                        Text("2. Toggle the switch ON").font(.caption2)
                        Text("3. You may need to unlock with your password first (🔒 icon)").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(Color.orange.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            Text("These permissions stay on your Mac. We never access your data.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()

            nextButton()
        }
    }

    // MARK: - Step 2b: Plan Selection

    private var planStep: some View {
        VStack(spacing: 16) {
            stepHeader(icon: "bolt.circle.fill", title: "How do you want to use TalkIsCheap?", subtitle: "You can change this anytime in Settings")

            Spacer()

            VStack(spacing: 10) {
                planCard(
                    emoji: "☁️",
                    title: "Use our cloud (recommended)",
                    subtitle: "Zero setup. We handle everything. 10 free uses, then from $9.99/mo.",
                    selected: selectedPlan == "cloud",
                    action: { selectedPlan = "cloud" }
                )
                planCard(
                    emoji: "🔑",
                    title: "Bring your own API keys",
                    subtitle: "Free unlimited. You set up Groq + Anthropic keys yourself.",
                    selected: selectedPlan == "byok",
                    action: { selectedPlan = "byok" }
                )
                planCard(
                    emoji: "💻",
                    title: "Offline mode",
                    subtitle: "Apple's on-device speech engine + Ollama polish (~2 GB). Fully private.",
                    selected: selectedPlan == "offline",
                    action: { selectedPlan = "offline" }
                )
            }

            Spacer()

            Button {
                // Apply plan selection
                switch selectedPlan {
                case "cloud":
                    settings.useCloudProxy = true
                    settings.sttProvider = "groq"
                    settings.polishProvider = "anthropic"
                    // Skip API keys step → go to localInstallStep (which auto-skips for cloud)
                    withAnimation { step = 4 }
                case "byok":
                    settings.useCloudProxy = false
                    settings.sttProvider = "groq"
                    settings.polishProvider = "anthropic"
                    // Show API keys step
                    withAnimation { step += 1 }
                case "offline":
                    settings.useCloudProxy = false
                    settings.sttProvider = "local"
                    settings.polishProvider = "ollama"
                    // Skip API keys → go to local install
                    withAnimation { step = 4 }
                default:
                    withAnimation { step += 1 }
                }
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    private func planCard(emoji: String, title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(emoji).font(.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.bold())
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue).font(.title3)
                }
            }
            .padding(12)
            .background(selected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 3: API Keys (only for BYOK)

    private var apiKeysStep: some View {
        VStack(spacing: 16) {
            stepHeader(icon: "key.fill", title: "Enter your API Keys", subtitle: "These are free to create. Your data goes directly to each API — we never see it.")

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Groq API Key (Speech-to-Text)").font(.caption.bold())
                    SecureField("gsk_...", text: $settings.groqApiKey).textFieldStyle(.roundedBorder)
                    Link("Get free key at console.groq.com →",
                         destination: URL(string: "https://console.groq.com/keys")!)
                        .font(.caption)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Anthropic API Key (Text Polishing)").font(.caption.bold())
                    SecureField("sk-ant-...", text: $settings.anthropicApiKey).textFieldStyle(.roundedBorder)
                    Link("Get key at console.anthropic.com →",
                         destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.caption)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Brave Search API Key (Voice Search — optional)").font(.caption.bold())
                    SecureField("BSA...", text: $settings.braveApiKey).textFieldStyle(.roundedBorder)
                    Link("Get free key at brave.com →",
                         destination: URL(string: "https://brave.com/search/api/")!)
                        .font(.caption)
                }
            }

            Spacer()

            // Skip local install for BYOK
            Button {
                withAnimation { step = 5 } // Jump to language
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - (old speechStep replaced by planStep above)

    private var speechStep_unused: some View {
        VStack(spacing: 16) {
            stepHeader(icon: "mic.fill", title: "Speech Recognition", subtitle: "Choose how TalkIsCheap hears you")

            Spacer()

            VStack(spacing: 12) {
                providerCard(
                    title: "☁️ Groq Cloud",
                    subtitle: "Blazing fast, highly accurate, free API key",
                    isSelected: settings.sttProvider == "groq",
                    action: { settings.sttProvider = "groq" }
                )
                providerCard(
                    title: "💻 Local (mlx-whisper)",
                    subtitle: "Fully offline, ~1.6GB download, slower",
                    isSelected: settings.sttProvider == "local",
                    action: { settings.sttProvider = "local" }
                )
            }

            if settings.sttProvider == "groq" {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Groq API Key").font(.caption.bold())
                        Spacer()
                        Text("OPTIONAL").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    SecureField("gsk_... (leave empty for 10 free uses)", text: $settings.groqApiKey)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Link("Get free key →", destination: URL(string: "https://console.groq.com/keys")!)
                            .font(.caption)
                        Spacer()
                        Text("Or leave empty to try with our keys (10 free uses)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 4)
            }

            Spacer()
            nextButton()
        }
    }

    // MARK: - Step 4: Polish Engine

    private var polishStep: some View {
        VStack(spacing: 16) {
            stepHeader(icon: "sparkles", title: "Text Polishing", subtitle: "AI cleans up grammar, removes filler words, and formats your text")

            Spacer()

            VStack(spacing: 12) {
                providerCard(
                    title: "☁️ Anthropic Claude",
                    subtitle: "Best quality, ~$0.001 per dictation",
                    isSelected: settings.polishProvider == "anthropic",
                    action: { settings.polishProvider = "anthropic" }
                )
                providerCard(
                    title: "💻 Ollama (Local)",
                    subtitle: "Free, offline, requires Ollama app installed",
                    isSelected: settings.polishProvider == "ollama",
                    action: { settings.polishProvider = "ollama" }
                )
            }

            if settings.polishProvider == "anthropic" {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Anthropic API Key").font(.caption.bold())
                        Spacer()
                        Text("OPTIONAL").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    SecureField("sk-ant-... (leave empty for 10 free uses)", text: $settings.anthropicApiKey)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Link("Get key →", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                            .font(.caption)
                        Spacer()
                        Text("Skip to try with our keys first")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 4)
            }

            Spacer()
            nextButton()
        }
    }

    // MARK: - Step 4b: Voice Search (Brave API Key)

    private var searchStep: some View {
        VStack(spacing: 16) {
            stepHeader(icon: "magnifyingglass", title: "Voice Search", subtitle: "Double-tap your hotkey to search the web with your voice")

            Spacer()

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.title)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Brave Search + Claude AI").font(.subheadline.bold())
                        Text("Ask any question, get an instant AI-summarized answer with sources.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Brave Search API Key").font(.caption.bold())
                    Spacer()
                    Text("OPTIONAL").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.15))
                        .clipShape(Capsule())
                }
                SecureField("BSA... (leave empty to use our keys)", text: $settings.braveApiKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Link("Get free key (2000/mo) →", destination: URL(string: "https://brave.com/search/api/")!)
                        .font(.caption)
                    Spacer()
                }
            }
            .padding(.top, 4)

            Text("Voice Search works with your trial keys too. Skip to use ours.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
            nextButton()
        }
    }

    // MARK: - Step 5: Local Install

    private var localInstallStep: some View {
        VStack(spacing: 16) {
            if !needsLocalInstall {
                // Skip this step — auto-advance
                Color.clear.onAppear {
                    withAnimation { step += 1 }
                }
            } else {
                stepHeader(icon: "arrow.down.circle", title: "Installing Local Mode",
                           subtitle: "Setting up offline speech recognition and AI polishing")

                Spacer()

                switch localSetup.state {
                case .idle:
                    VStack(spacing: 12) {
                        installRow(icon: "cpu", text: "Python environment", size: "~50 MB")
                        if settings.sttProvider == "local" {
                            installRow(icon: "mic.fill", text: "Whisper speech model", size: "~1.6 GB")
                        }
                        if settings.polishProvider == "ollama" {
                            installRow(icon: "sparkles", text: "Ollama + language model", size: "~1.9 GB")
                        }

                        Text("This may take a few minutes depending on your internet speed.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }

                    Spacer()

                    Button {
                        Task {
                            await localSetup.setupLocalMode(
                                needsSTT: settings.sttProvider == "local",
                                needsPolish: settings.polishProvider == "ollama"
                            )
                        }
                    } label: {
                        Label("Install Now", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)

                    skipButton("Skip — use cloud mode instead") {
                        settings.sttProvider = "groq"
                        settings.polishProvider = "anthropic"
                        withAnimation { step += 1 }
                    }

                case .installing(let stepText):
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text(stepText)
                            .font(.subheadline.weight(.medium))
                        Text("Please don't close the app during installation.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                case .done:
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.green)
                        Text("Local mode installed!")
                            .font(.title3.bold())
                        Text("Everything is set up for fully offline dictation.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    nextButton()

                case .error(let msg):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.orange)
                        Text("Installation issue")
                            .font(.title3.bold())
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Spacer()

                    Button {
                        Task {
                            await localSetup.setupLocalMode(
                                needsSTT: settings.sttProvider == "local",
                                needsPolish: settings.polishProvider == "ollama"
                            )
                        }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)

                    skipButton("Switch to cloud mode") {
                        settings.sttProvider = "groq"
                        settings.polishProvider = "anthropic"
                        withAnimation { step += 1 }
                    }
                }
            }
        }
    }

    private func installRow(icon: String, text: String, size: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)
            Text(text)
                .font(.subheadline)
            Spacer()
            Text(size)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Step 5: Language

    private var languageStep: some View {
        VStack(spacing: 16) {
            stepHeader(icon: "globe", title: "Language", subtitle: "Pick your primary language or let TalkIsCheap auto-detect")

            Spacer()

            Picker("Language", selection: $settings.language) {
                ForEach(AppSettings.languages, id: \.code) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
            .pickerStyle(.radioGroup)

            Text("You can switch languages anytime from Settings.\nTalkIsCheap also supports mixing languages mid-sentence.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
            nextButton()
        }
    }

    // MARK: - Step 6: How to Dictate

    private var howToDictateStep: some View {
        VStack(spacing: 16) {
            stepHeader(icon: "keyboard", title: "How to Dictate", subtitle: "Three ways to use your voice")

            Spacer()

            VStack(spacing: 14) {
                hotkeyCard(
                    keys: "Hold Hotkey",
                    title: "Push-to-Talk",
                    desc: "Hold the key, speak, release. Text appears at your cursor.",
                    color: .blue
                )

                hotkeyCard(
                    keys: "Hotkey + Shift",
                    title: "Hands-Free Mode",
                    desc: "Hold both keys to start, release when done. For longer dictation.",
                    color: .purple
                )

                hotkeyCard(
                    keys: "Double-tap",
                    title: "Voice Search",
                    desc: "Tap your hotkey twice, ask a question. AI searches the web and answers.",
                    color: .orange
                )
            }

            Spacer()
            nextButton()
        }
    }

    // MARK: - Step 7: Polish Modes

    private var polishModesStep: some View {
        VStack(spacing: 16) {
            stepHeader(icon: "wand.and.stars", title: "Polish Modes", subtitle: "Choose how your text gets cleaned up")

            Spacer()

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(PolishMode.builtIn) { mode in
                    HStack(spacing: 8) {
                        Text(mode.emoji).font(.title3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mode.label).font(.caption.bold())
                            Text(modeDescription(mode.id)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(settings.activePolishMode == mode.id ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(settings.activePolishMode == mode.id ? Color.accentColor : .clear, lineWidth: 1.5)
                    )
                    .onTapGesture { settings.activePolishMode = mode.id }
                }
            }

            VStack(spacing: 4) {
                Text("Switch modes anytime from the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Create unlimited custom modes in Settings → Scenarios.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
            nextButton()
        }
    }

    // MARK: - Step 8: Ready

    private var readyStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
                .shadow(color: .green.opacity(0.3), radius: 20)

            Text("You're all set!")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            Text("Quick Reference")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 10) {
                refRow(keys: "Hold Hotkey", action: "Dictate (push-to-talk)")
                refRow(keys: "Hotkey+Shift", action: "Hands-free dictation")
                refRow(keys: "2× Hotkey", action: "Voice Search")
                refRow(keys: "Right-click file", action: "Transcribe & Summarize")
                refRow(keys: "Menu bar icon", action: "Settings, modes, history")
            }
            .padding(16)
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 4) {
                Image(systemName: "gift").font(.caption)
                Text("10 free uses included — no API keys needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    // Start trial for cloud users (zero setup path)
                    if selectedPlan == "cloud" || settings.useCloudProxy {
                        _ = await ProxyClient.startTrial()
                    }
                    await MainActor.run {
                        settings.hasCompletedOnboarding = true
                        dismiss()
                    }
                }
            } label: {
                Text("Start Using TalkIsCheap")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Helper Components

    private func stepHeader(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.blue)
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func featureBullet(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.blue)
                .frame(width: 24)
            Text(text)
                .font(.body)
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private func permissionCard(icon: String, title: String, desc: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(granted ? .green : .blue)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            } else {
                Button("Grant") { action() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(granted ? Color.green.opacity(0.05) : Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(granted ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1.5)
        )
    }

    private func hotkeyCard(keys: String, title: String, desc: String, color: Color) -> some View {
        HStack(spacing: 14) {
            Text(keys)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(color.opacity(0.1))
                .foregroundStyle(color)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(width: 120)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.secondary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func refRow(keys: String, action: String) -> some View {
        HStack {
            Text(keys)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(width: 120, alignment: .leading)
            Text(action)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func modeDescription(_ id: String) -> String {
        switch id {
        case "fast": return "Direct transcription — no polish, fastest path"
        case "clean": return "Fix punctuation & filler words"
        case "professional": return "Business communication"
        case "marketing": return "Punchy, benefit-driven copy"
        case "email": return "Structured email format"
        case "coding": return "Technical documentation"
        case "casual": return "Chat message style"
        case "claude_prompt": return "Generate Claude AI prompts"
        case "chatgpt_prompt": return "Generate ChatGPT prompts"
        default: return ""
        }
    }

    private func nextButton(_ label: String = "Continue") -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) { step += 1 }
        } label: {
            Text(label)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
    }

    private func skipButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private func providerCard(title: String, subtitle: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.title3)
                }
            }
            .padding(12)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}
