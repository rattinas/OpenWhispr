import SwiftUI
import UniformTypeIdentifiers

struct MenuBarView: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var modeManager = PolishModeManager.shared
    @ObservedObject var history = TranscriptionHistory.shared
    @ObservedObject var updateChecker = UpdateChecker.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status
            HStack {
                statusIcon
                Text(state.statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Polish Mode
            Menu {
                ForEach(PolishMode.builtIn) { mode in
                    Button {
                        settings.activePolishMode = mode.id
                    } label: {
                        HStack {
                            Text("\(mode.emoji) \(mode.label)")
                            if settings.activePolishMode == mode.id { Image(systemName: "checkmark") }
                        }
                    }
                }
                if !modeManager.customModes.isEmpty {
                    Divider()
                    ForEach(modeManager.customModes) { mode in
                        Button {
                            settings.activePolishMode = mode.id
                        } label: {
                            HStack {
                                Text("⭐ \(mode.label)")
                                if settings.activePolishMode == mode.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            } label: {
                let active = modeManager.allModes.first { $0.id == settings.activePolishMode }
                Label("\(active?.emoji ?? "✨") \(active?.label ?? "Clean")", systemImage: "sparkles")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)

            // Quick stats
            if history.totalCount > 0 {
                HStack {
                    Text("\(history.todayWordCount) words today")
                    Spacer()
                    Text("\(history.totalCount) total")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12).padding(.vertical, 4)
            }

            Divider()

            // Voice Search hint / Trial expired warning
            if !LicenseManager.canUse {
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 9))
                        Text("Trial expired").font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.orange)

                    Button {
                        NotificationCenter.default.post(name: .showPaywall, object: nil)
                    } label: {
                        Label("Upgrade — from $9.99/mo or $19 lifetime", systemImage: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 9))
                    Text("Voice Search: double-tap your hotkey").font(.system(size: 10))
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12).padding(.vertical, 4)
            }

            Divider()

            Button {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.audio, .movie, .mpeg4Audio, .mpeg4Movie, .wav, .mp3, .pdf,
                                              .init(filenameExtension: "docx")!]
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.title = "Choose audio, video, PDF, or Word file"
                if panel.runModal() == .OK, let url = panel.url {
                    FileTranscriptionManager.shared.processFile(path: url.path)
                }
            } label: {
                Label("Open File...", systemImage: "doc.badge.waveform")
            }
            .disabled(!LicenseManager.canUse)
            .padding(.horizontal, 8).padding(.vertical, 4)

            Button {
                openWindow(id: "history")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("History", systemImage: "clock")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)

            SettingsLink {
                Label("Settings", systemImage: "gear")
            }
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate(ignoringOtherApps: true)
            })
            .padding(.horizontal, 8).padding(.vertical, 4)

            Divider()

            // Quick info — engine labels per mode
            HStack(spacing: 4) {
                Image(systemName: transcribeEngineIcon).font(.system(size: 9))
                Text(transcribeEngineLabel).font(.system(size: 10))
                Text("→").font(.system(size: 9))
                Image(systemName: settings.polishProvider == "anthropic" ? "cloud" : "desktopcomputer").font(.system(size: 9))
                Text(settings.polishProvider == "anthropic" ? "Claude" : "Ollama").font(.system(size: 10))
                Spacer()
                if LicenseManager.isLicensed {
                    Text("Licensed").font(.system(size: 9, weight: .medium)).foregroundStyle(.green)
                } else {
                    Text("\(settings.remainingTrial) left").font(.system(size: 9, weight: .medium)).foregroundStyle(.orange)
                }
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12).padding(.vertical, 6)

            Divider()

            // Update available
            if updateChecker.updateAvailable {
                Button {
                    updateChecker.openDownloadPage()
                } label: {
                    Label("🔄 Update \(updateChecker.latestVersion) available", systemImage: "arrow.down.circle")
                        .foregroundStyle(.blue)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)

                Divider()
            }

            // Toggles
            Toggle(isOn: $settings.dimAudioWhileRecording) {
                Label("Dim audio while recording", systemImage: "speaker.wave.2")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)

            Toggle(isOn: $settings.appAwareContext) {
                Label("App-aware context", systemImage: "app.badge.checkmark")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)

            Toggle(isOn: Binding(
                get: { EqualizerOverlay.shared.isEnabled },
                set: { EqualizerOverlay.shared.isEnabled = $0 }
            )) {
                Label("Cassette overlay", systemImage: "cassette")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)

            Divider()

            // Permissions warning
            if !PermissionManager.accessibilityGranted {
                Button {
                    PermissionManager.openAccessibilitySettings()
                } label: {
                    Label("⚠️ Grant Accessibility", systemImage: "hand.raised")
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }

            Button("Quit TalkIsCheap") {
                NSApplication.shared.terminate(nil)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .frame(width: 270)
    }

    private var transcribeEngineLabel: String {
        if settings.shouldUseProxy { return "TalkIsCheap Server" }
        if settings.sttProvider == "local" { return "Apple (local)" }
        return "Groq Whisper"
    }

    private var transcribeEngineIcon: String {
        if settings.shouldUseProxy { return "sparkles" }
        if settings.sttProvider == "local" { return "desktopcomputer" }
        return "cloud"
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state.status {
        case .recording:
            Circle().fill(.red).frame(width: 8, height: 8)
        case .transcribing, .polishing:
            ProgressView().scaleEffect(0.5)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 10))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 10))
        default:
            Circle().fill(.green).frame(width: 8, height: 8)
        }
    }
}
