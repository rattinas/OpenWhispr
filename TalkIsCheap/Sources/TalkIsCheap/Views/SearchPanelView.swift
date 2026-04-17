import SwiftUI
import AppKit

@MainActor
final class SearchPanelManager: ObservableObject {
    static let shared = SearchPanelManager()

    enum State {
        case hidden
        case listening
        case searching(query: String)
        case result(SearchResult)
        case error(String)
    }

    @Published var state: State = .hidden
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
                backing: .buffered,
                defer: true
            )
            p.title = "TalkIsCheap Search"
            p.isFloatingPanel = true
            p.level = .floating
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isMovableByWindowBackground = true
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.backgroundColor = NSColor.windowBackgroundColor

            let hostView = NSHostingView(rootView: SearchResultView())
            p.contentView = hostView
            self.panel = p
        }

        centerOnScreen()
        panel?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        panel?.orderOut(nil)
        state = .hidden
    }

    func showResult(_ result: SearchResult) {
        state = .result(result)
        show()
    }

    func showError(_ message: String) {
        state = .error(message)
    }

    private func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        panel?.setFrameOrigin(NSPoint(x: f.midX - 300, y: f.midY - 100))
    }
}

// MARK: - SwiftUI View

struct SearchResultView: View {
    @ObservedObject var manager = SearchPanelManager.shared
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            switch manager.state {
            case .hidden:
                EmptyView()
            case .listening:
                listeningView
            case .searching(let query):
                searchingView(query)
            case .result(let result):
                resultView(result)
            case .error(let msg):
                errorView(msg)
            }
        }
        .frame(width: 760, height: 620)
    }

    // MARK: - Listening

    private var listeningView: some View {
        VStack(spacing: 16) {
            Spacer()
            CassetteView(isActive: true)
                .scaleEffect(2.0)
                .frame(height: 80)
            Text("Listening...")
                .font(.title3.weight(.medium))
            Text("Ask anything — release to search")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(40)
    }

    // MARK: - Searching

    private func searchingView(_ query: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Searching...")
                .font(.title3.weight(.medium))
            Text("\"" + query + "\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(40)
    }

    // MARK: - Result

    private func resultView(_ result: SearchResult) -> some View {
        VStack(spacing: 0) {
            // Search bar header
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))
                Text(result.query)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.answer, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Copy answer")

                Button { manager.hide() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            // Answer + Images
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Images row
                    if !result.images.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(result.images, id: \.self) { imageURL in
                                    AsyncImage(url: URL(string: imageURL)) { phase in
                                        switch phase {
                                        case .success(let image):
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 140, height: 100)
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                        case .failure:
                                            EmptyView()
                                        default:
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(Color.secondary.opacity(0.1))
                                                .frame(width: 140, height: 100)
                                                .overlay(ProgressView().scaleEffect(0.6))
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Answer text — rendered as Markdown
                    if let md = try? AttributedString(markdown: result.answer, options: .init(interpretedSyntax: .full)) {
                        Text(md)
                            .font(.system(size: 14))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(result.answer)
                            .font(.system(size: 14))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Sources
                    if !result.sources.isEmpty {
                        Divider()

                        Text("Sources")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(Array(result.sources.enumerated()), id: \.offset) { i, source in
                                sourceCard(index: i + 1, title: source.title, url: source.url)
                            }
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            // Bottom bar
            HStack {
                Text("Esc to close")
                Spacer()
                // Response depth indicator
                HStack(spacing: 4) {
                    Text("Depth:")
                    ForEach(["minimal", "balanced", "detailed"], id: \.self) { level in
                        Text(level == "minimal" ? "🗿" : level == "balanced" ? "📝" : "📚")
                            .opacity(settings.searchDepth == level ? 1 : 0.3)
                            .onTapGesture { settings.searchDepth = level }
                    }
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    private func sourceCard(index: Int, title: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            HStack(spacing: 8) {
                // Favicon placeholder
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(red: 0.95, green: 0.35, blue: 0.25).opacity(0.1))
                        .frame(width: 28, height: 28)
                    Text("\(index)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(red: 0.95, green: 0.35, blue: 0.25))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(URL(string: url)?.host ?? url)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Search Failed")
                .font(.title3.weight(.medium))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Close") { manager.hide() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            Spacer()
        }
        .padding(20)
    }
}
