import SwiftUI

@MainActor
final class FileTranscriptionManager: ObservableObject {
    static let shared = FileTranscriptionManager()

    enum State {
        case hidden
        case transcribing(fileName: String)
        case summarizing
        case ready(transcript: String, summary: String, filePath: String)
    }

    @Published var state: State = .hidden
    @Published var chatMessages: [(role: String, text: String)] = []
    private var currentTranscript = ""
    private var panel: NSPanel?

    func processFile(path: String) {
        guard LicenseManager.canUse else {
            state = .ready(transcript: "", summary: "Trial expired — enter license key in Settings to continue.", filePath: path)
            SoundFeedback.error()
            show()
            return
        }

        let fileName = URL(fileURLWithPath: path).lastPathComponent
        state = .transcribing(fileName: fileName)
        chatMessages = []
        show()

        Task {
            do {
                // 1. Transcribe
                let transcript = try await FileTranscriptionService.shared.transcribe(filePath: path)
                currentTranscript = transcript

                // Save .txt
                FileTranscriptionService.shared.saveTranscript(filePath: path, transcript: transcript)

                // 2. Summarize
                state = .summarizing
                let summary = try await FileTranscriptionService.shared.summarize(transcript: transcript)

                SoundFeedback.done()
                state = .ready(transcript: transcript, summary: summary, filePath: path)

            } catch {
                Log.write("File transcription error: \(error)")
                SoundFeedback.error()
                state = .ready(transcript: "Error: \(error.localizedDescription)", summary: "", filePath: path)
            }
        }
    }

    func askQuestion(_ question: String) {
        guard LicenseManager.canUse else { return }
        guard !currentTranscript.isEmpty else { return }
        chatMessages.append((role: "user", text: question))

        Task {
            do {
                let answer = try await FileTranscriptionService.shared.askQuestion(
                    transcript: currentTranscript, question: question
                )
                await MainActor.run {
                    chatMessages.append((role: "assistant", text: answer))
                }
            } catch {
                await MainActor.run {
                    chatMessages.append((role: "assistant", text: "⚠️ \(error.localizedDescription)"))
                }
            }
        }
    }

    func show() {
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 650, height: 550),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            p.title = "TalkIsCheap — File Transcription"
            p.isFloatingPanel = true
            p.level = .floating
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.backgroundColor = NSColor.windowBackgroundColor

            let hostView = NSHostingView(rootView: FileTranscriptionView())
            p.contentView = hostView
            self.panel = p
        }

        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        panel?.setFrameOrigin(NSPoint(x: f.midX - 325, y: f.midY - 200))
        panel?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel?.orderOut(nil)
        state = .hidden
    }
}

struct FileTranscriptionView: View {
    @ObservedObject var manager = FileTranscriptionManager.shared
    @State private var selectedTab = "transcript"
    @State private var questionText = ""

    var body: some View {
        VStack(spacing: 0) {
            switch manager.state {
            case .hidden:
                EmptyView()

            case .transcribing(let fileName):
                loadingView(title: "Transcribing...", subtitle: fileName)

            case .summarizing:
                loadingView(title: "Summarizing...", subtitle: "AI is analyzing the content")

            case .ready(let transcript, let summary, _):
                readyView(transcript: transcript, summary: summary)
            }
        }
        .frame(width: 650, height: 550)
    }

    private func loadingView(title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            CassetteView(isActive: true)
                .scaleEffect(2.5)
                .frame(height: 100)
            Text(title)
                .font(.title3.weight(.medium))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
    }

    private func readyView(transcript: String, summary: String) -> some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                tabButton("Transcript", icon: "doc.text", tab: "transcript")
                tabButton("Summary", icon: "sparkles", tab: "summary")
                tabButton("Ask", icon: "bubble.left.and.bubble.right", tab: "chat")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Divider().padding(.top, 8)

            // Tab content
            switch selectedTab {
            case "transcript":
                transcriptTab(transcript)
            case "summary":
                summaryTab(summary)
            case "chat":
                chatTab()
            default:
                transcriptTab(transcript)
            }
        }
    }

    private func tabButton(_ title: String, icon: String, tab: String) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(selectedTab == tab ? Color.accentColor.opacity(0.1) : Color.clear)
            .clipShape(Capsule())
        }
        .buttonStyle(.borderless)
    }

    private func transcriptTab(_ transcript: String) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(transcript)
                    .font(.system(size: 13))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }

            Divider()
            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("\(transcript.split(separator: " ").count) words")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(10)
        }
    }

    private func summaryTab(_ summary: String) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                if let md = try? AttributedString(markdown: summary, options: .init(interpretedSyntax: .full)) {
                    Text(md)
                        .font(.system(size: 13))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    Text(summary)
                        .font(.system(size: 13))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }

            Divider()
            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
        }
    }

    private func chatTab() -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if manager.chatMessages.isEmpty {
                        Text("Ask any question about this file...")
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, 60)
                    }

                    ForEach(Array(manager.chatMessages.enumerated()), id: \.offset) { _, msg in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: msg.role == "user" ? "person.circle" : "sparkle")
                                .font(.system(size: 14))
                                .foregroundStyle(msg.role == "user" ? .blue : .orange)
                                .frame(width: 20)

                            if let md = try? AttributedString(markdown: msg.text, options: .init(interpretedSyntax: .full)) {
                                Text(md)
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)
                            } else {
                                Text(msg.text)
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Ask about this file...", text: $questionText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { sendQuestion() }

                Button {
                    sendQuestion()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.borderless)
                .disabled(questionText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
    }

    private func sendQuestion() {
        let q = questionText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        questionText = ""
        manager.askQuestion(q)
    }
}
