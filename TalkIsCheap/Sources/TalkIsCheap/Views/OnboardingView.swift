import SwiftUI

struct OnboardingView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var step = 0
    @Environment(\.dismiss) private var dismiss

    private let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.1))
                    Rectangle().fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(step + 1) / CGFloat(totalSteps))
                        .animation(.easeInOut, value: step)
                }
            }
            .frame(height: 3)

            // Content
            Group {
                switch step {
                case 0: welcomeStep
                case 1: speechStep
                case 2: polishStep
                case 3: languageStep
                case 4: doneStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        }
        .frame(width: 480, height: 400)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("TalkIsCheap")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            Text("Your voice, polished and pasted.\nHold a key, speak, release.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Spacer()

            nextButton("Get Started")
        }
    }

    private var speechStep: some View {
        VStack(spacing: 16) {
            Label("Speech Recognition", systemImage: "mic.fill")
                .font(.title2.bold())

            Text("How should TalkIsCheap understand your voice?")
                .foregroundStyle(.secondary)

            Spacer()

            VStack(spacing: 12) {
                providerCard(
                    title: "☁️ Groq Cloud",
                    subtitle: "Fast, accurate, free API key",
                    isSelected: settings.sttProvider == "groq",
                    action: { settings.sttProvider = "groq" }
                )
                providerCard(
                    title: "💻 Local Whisper",
                    subtitle: "Fully offline, ~1.6GB download",
                    isSelected: settings.sttProvider == "local",
                    action: { settings.sttProvider = "local" }
                )
            }

            if settings.sttProvider == "groq" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Groq API Key").font(.caption.bold())
                    SecureField("gsk_...", text: $settings.groqApiKey)
                        .textFieldStyle(.roundedBorder)
                    Link("Get free key at console.groq.com →",
                         destination: URL(string: "https://console.groq.com/keys")!)
                        .font(.caption)
                }
                .padding(.top, 8)
            }

            Spacer()
            nextButton()
        }
    }

    private var polishStep: some View {
        VStack(spacing: 16) {
            Label("Text Polishing", systemImage: "sparkles")
                .font(.title2.bold())

            Text("How should TalkIsCheap clean up your text?")
                .foregroundStyle(.secondary)

            Spacer()

            VStack(spacing: 12) {
                providerCard(
                    title: "☁️ Anthropic Claude",
                    subtitle: "Best quality, ~$0.001/dictation",
                    isSelected: settings.polishProvider == "anthropic",
                    action: { settings.polishProvider = "anthropic" }
                )
                providerCard(
                    title: "💻 Ollama",
                    subtitle: "Free, offline, requires Ollama app",
                    isSelected: settings.polishProvider == "ollama",
                    action: { settings.polishProvider = "ollama" }
                )
            }

            if settings.polishProvider == "anthropic" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Anthropic API Key").font(.caption.bold())
                    SecureField("sk-ant-...", text: $settings.anthropicApiKey)
                        .textFieldStyle(.roundedBorder)
                    Link("Get key at console.anthropic.com →",
                         destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.caption)
                }
                .padding(.top, 8)
            }

            Spacer()
            nextButton()
        }
    }

    private var languageStep: some View {
        VStack(spacing: 16) {
            Label("Language", systemImage: "globe")
                .font(.title2.bold())

            Text("What language do you speak?")
                .foregroundStyle(.secondary)

            Spacer()

            Picker("Language", selection: $settings.language) {
                ForEach(AppSettings.languages, id: \.code) { lang in
                    Text(lang.name).tag(lang.code)
                }
            }
            .pickerStyle(.radioGroup)

            Spacer()
            nextButton()
        }
    }

    private var doneStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text("You're all set!")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            VStack(alignment: .leading, spacing: 8) {
                Label("Hold **Control** to record", systemImage: "keyboard")
                Label("Release to paste polished text", systemImage: "doc.on.clipboard")
                Label("Click 🎤 in menu bar for settings", systemImage: "menubar.rectangle")
            }
            .font(.body)

            Spacer()

            Button {
                settings.hasCompletedOnboarding = true
                dismiss()
            } label: {
                Text("Start Using TalkIsCheap")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Helpers

    private func nextButton(_ label: String = "Continue") -> some View {
        Button {
            withAnimation { step += 1 }
        } label: {
            Text(label)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
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
