import SwiftUI
import AppKit

struct ChatTurn: Identifiable, Hashable {
    let id = UUID()
    enum Role: Hashable { case user, assistant }
    let role: Role
    var text: String
    var isStreaming: Bool = false
}

@MainActor
final class SearchPanelManager: ObservableObject {
    static let shared = SearchPanelManager()

    enum State {
        case hidden
        case listening
        case searching(query: String)
        case result(SearchResult)
        case streaming(query: String, partialAnswer: String, sources: [SearchSource], images: [String], widgetUrl: String?)
        case error(String)
    }

    @Published var state: State = .hidden
    @Published var conversation: [ChatTurn] = []
    @Published var isThinking = false
    private var panel: NSPanel?

    /// The original SearchResult stored so follow-up chat can reason over
    /// its rawData / follow-up context. Set when we enter .result state.
    private var lastResult: SearchResult?

    // MARK: Streaming helpers

    func startStreaming(query: String) {
        state = .streaming(query: query, partialAnswer: "", sources: [], images: [], widgetUrl: nil)
    }

    func updateStreamingSources(sources: [SearchSource], images: [String], widgetUrl: String?) {
        guard case .streaming(let q, let a, _, _, _) = state else { return }
        state = .streaming(query: q, partialAnswer: a, sources: sources, images: images, widgetUrl: widgetUrl)
    }

    func appendStreamingDelta(_ text: String) {
        guard case .streaming(let q, let a, let s, let i, let w) = state else { return }
        state = .streaming(query: q, partialAnswer: a + text, sources: s, images: i, widgetUrl: w)
    }

    func finalizeStreaming() {
        guard case .streaming(let q, let a, let s, let i, let w) = state else { return }
        state = .result(SearchResult(query: q, answer: a, sources: s, images: i, widgetUrl: w))
    }

    func show() {
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
                backing: .buffered,
                defer: true
            )
            p.title = "TalkIsCheap Command"
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
        conversation = []
        lastResult = nil
    }

    func showResult(_ result: SearchResult) {
        state = .result(result)
        lastResult = result
        conversation = []
        show()
    }

    func showError(_ message: String) {
        state = .error(message)
    }

    // MARK: - Chat / follow-up

    /// Send a free-text follow-up question. Claude Haiku answers using the
    /// original result's rawData as context + prior conversation.
    func sendFollowUp(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let base = lastResult else { return }

        conversation.append(ChatTurn(role: .user, text: trimmed))
        isThinking = true

        let system = """
        You are a follow-up assistant inside a voice-first productivity app. \
        The user just received an initial answer from one of our connectors \
        (Gmail, Google Calendar, …) and now wants to drill deeper, draft \
        replies, summarise, or ask questions.

        CRITICAL RULES:
        - ALWAYS respond in the EXACT same language as the user's NEW \
          question. Not the initial answer, not the context — the new \
          question decides. German question → German answer. English \
          → English. Never mix or switch mid-answer.
        - Use the CONTEXT (raw connector data) as the authoritative \
          source of facts. Don't invent information.
        - When the user refers to a numbered item ("reply to #2", \
          "summarise #1"), find that item in the context by its index.
        - When drafting an email reply: output ONLY the email body text. \
          No subject line, no "Here's a draft:" preamble, no explanation \
          of what you did. Plain body text ready to copy-paste.
        - When answering a factual question: lead with the answer, keep \
          it tight, quote from the context when useful.
        - Default to concise unless the user asks for detail.
        """

        var userContent = ""
        userContent += "## Original answer\n\n\(base.answer)\n\n"
        if let ctx = base.followUpContext, !ctx.isEmpty {
            userContent += "## Context (raw data from the connector)\n\n\(ctx)\n\n"
        }
        if conversation.count > 1 {
            userContent += "## Conversation so far\n\n"
            for turn in conversation.dropLast() {
                let who = turn.role == .user ? "User" : "Assistant"
                userContent += "**\(who):** \(turn.text)\n\n"
            }
        }
        userContent += "## New question\n\n\(trimmed)"

        do {
            let answer = try await ProxyClient.polish(
                text: userContent,
                systemPrompt: system,
                model: "claude-haiku-4-5-20251001"
            )
            conversation.append(ChatTurn(role: .assistant, text: answer))
        } catch {
            conversation.append(ChatTurn(
                role: .assistant,
                text: "⚠️ Couldn't generate an answer: \(error.localizedDescription)"
            ))
        }
        isThinking = false
    }

    /// Copy an assistant answer to the clipboard — handy for pasting
    /// drafted email replies back into Gmail.
    func copyTurn(_ turn: ChatTurn) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(turn.text, forType: .string)
    }

    // MARK: - Confirm a pending agent action

    @Published var isExecutingAction = false

    /// Actually execute the agent-prepared write action using the current
    /// (possibly user-edited) field values. Replaces the result with a
    /// success confirmation or surfaces an error in the chat.
    func confirmPending(_ action: PendingAction, editedValues: [String: String]) async {
        isExecutingAction = true
        defer { isExecutingAction = false }

        // Assemble the upstream payload from the edited fields + hidden fields.
        let payload: [String: Any]
        switch action.kind {
        case "gmail.send":
            let to = editedValues["to"] ?? ""
            let subject = editedValues["subject"] ?? ""
            let body = editedValues["body"] ?? ""
            let threadId = action.hidden["threadId"] ?? ""
            var mime = "To: \(to)\r\n"
            mime += "Subject: \(subject)\r\n"
            mime += "Content-Type: text/plain; charset=UTF-8\r\n\r\n"
            mime += body
            let raw = Data(mime.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            var p: [String: Any] = ["raw": raw]
            if !threadId.isEmpty { p["threadId"] = threadId }
            payload = p

        case "calendar.create":
            let summary = editedValues["summary"] ?? ""
            let location = editedValues["location"] ?? ""
            let description = editedValues["description"] ?? ""
            let tz = action.hidden["timezone"] ?? TimeZone.current.identifier
            let startISO = action.hidden["startISO"] ?? ""
            let endISO = action.hidden["endISO"] ?? ""
            var p: [String: Any] = [
                "summary": summary,
                "start": ["dateTime": startISO, "timeZone": tz],
                "end":   ["dateTime": endISO,   "timeZone": tz],
            ]
            if !location.isEmpty { p["location"] = location }
            if !description.isEmpty { p["description"] = description }
            if let csv = editedValues["attendeesCsv"]?
                .split(separator: ",")
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .filter({ !$0.isEmpty && $0.contains("@") }),
               !csv.isEmpty {
                p["attendees"] = csv.map { ["email": $0] }
            }
            payload = p

        default:
            conversation.append(ChatTurn(role: .assistant,
                text: "⚠️ Unknown action kind: \(action.kind)"))
            return
        }

        // Look up the Pipedream account for the app slug.
        await PipedreamCatalog.shared.ensureAccountsLoaded()
        guard let account = PipedreamCatalog.shared.account(forApp: action.appSlug) else {
            conversation.append(ChatTurn(role: .assistant,
                text: "⚠️ \(action.appSlug) isn't connected."))
            return
        }

        do {
            let data = try await PipedreamClient.shared.proxy(
                accountId: account.id,
                url: action.endpoint,
                method: action.method,
                body: payload
            )
            let respJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let err = respJson?["error"] as? [String: Any],
               let msg = err["message"] as? String {
                conversation.append(ChatTurn(role: .assistant, text: "⚠️ \(msg)"))
                return
            }

            // Build a success answer + replace the result so the confirm
            // UI disappears.
            let successMd = buildSuccessConfirmation(action: action, response: respJson)
            if case .result(let base) = state {
                let updated = SearchResult(
                    query: base.query,
                    answer: successMd,
                    sources: base.sources,
                    images: base.images,
                    widgetUrl: base.widgetUrl,
                    connectorId: base.connectorId,
                    connectorName: base.connectorName,
                    connectorIcon: base.connectorIcon,
                    followUpContext: base.followUpContext,
                    pendingAction: nil
                )
                state = .result(updated)
                lastResult = updated
            }
        } catch {
            conversation.append(ChatTurn(role: .assistant,
                text: "⚠️ Couldn't execute: \(error.localizedDescription)"))
        }
    }

    private func buildSuccessConfirmation(action: PendingAction, response: [String: Any]?) -> String {
        switch action.kind {
        case "gmail.send":
            let sentId = response?["id"] as? String ?? ""
            var md = "## ✅ E-Mail gesendet\n\n"
            if !sentId.isEmpty {
                md += "[In Gmail öffnen](https://mail.google.com/mail/u/0/#sent/\(sentId))"
            }
            return md
        case "calendar.create":
            let htmlLink = response?["htmlLink"] as? String ?? ""
            var md = "## ✅ Termin erstellt\n\n"
            if !htmlLink.isEmpty {
                md += "[Im Kalender öffnen](\(htmlLink))"
            }
            return md
        default:
            return "## ✅ Done"
        }
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
            case .streaming(let query, let partialAnswer, let sources, let images, let widgetUrl):
                resultView(SearchResult(
                    query: query,
                    answer: partialAnswer.isEmpty ? "…" : partialAnswer,
                    sources: sources,
                    images: images,
                    widgetUrl: widgetUrl
                ))
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
            Text("Listening…")
                .font(.title3.weight(.medium))
            Text("Ask anything — release when you're done")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Discoverability: show what kinds of commands work so users
            // realise this isn't just web search.
            if settings.commandsUnlocked {
                VStack(alignment: .leading, spacing: 6) {
                    exampleRow("magnifyingglass", "\"Was macht Bitcoin gerade?\"")
                    exampleRow("cart", "\"Shopify Umsatz heute\"")
                    exampleRow("creditcard", "\"Stripe Einnahmen diesen Monat\"")
                    exampleRow("chevron.left.slash.chevron.right", "\"Offene GitHub Issues\"")
                    exampleRow("chart.xyaxis.line", "\"GA4 Sessions gestern\"")
                }
                .padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    exampleRow("magnifyingglass", "\"Was macht Bitcoin gerade?\"")
                    exampleRow("person", "\"Wer ist …?\"")
                    exampleRow("chart.xyaxis.line", "\"Tesla Aktienkurs\"")
                }
                .padding(.top, 8)
            }
            Spacer()
        }
        .padding(40)
    }

    private func exampleRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Thinking

    private func searchingView(_ query: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Thinking…")
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
                if let icon = result.connectorIcon {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                } else {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                }
                Text(result.query)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                if let name = result.connectorName {
                    Text(name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.8))
                        .clipShape(Capsule())
                }
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

                    // Answer text — render each line as its own Text so
                    // explicit `\n` in the source (bullet lists, calendar
                    // rows) actually break visually. SwiftUI's full-markdown
                    // AttributedString parser flattens block-level structure
                    // into one paragraph, so we parse line-by-line and apply
                    // inline markdown per line.
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(result.answer.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                                Spacer().frame(height: 4)
                            } else if let attr = try? AttributedString(
                                markdown: line,
                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                            ) {
                                Text(attr)
                                    .font(.system(size: 14))
                                    .lineSpacing(4)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(line)
                                    .font(.system(size: 14))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Financial widget link (crypto / stock queries)
                    if let widgetUrl = result.widgetUrl, let url = URL(string: widgetUrl) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chart.xyaxis.line")
                                    .foregroundStyle(Color(red: 0.95, green: 0.35, blue: 0.25))
                                Text("View Chart on TradingView")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(10)
                            .background(Color(red: 0.95, green: 0.35, blue: 0.25).opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.borderless)
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

                    // Pending agent action: editable preview + Confirm / Cancel
                    if let pending = result.pendingAction {
                        pendingActionCard(pending)
                    }

                    // Chat / follow-up conversation
                    if !manager.conversation.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(manager.conversation) { turn in
                                chatBubble(turn)
                            }
                            if manager.isThinking {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.5)
                                    Text("Thinking…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    // Quick-action buttons — connector-specific
                    if let connectorId = result.connectorId {
                        quickActions(for: connectorId)
                    }
                }
                .padding(20)
            }

            Divider()

            // Chat input row
            chatInput

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

    // MARK: - Pending-action (editable) card

    @State private var editedFields: [UUID: String] = [:]

    @ViewBuilder
    private func pendingActionCard(_ action: PendingAction) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: action.kind.hasPrefix("gmail") ? "envelope.fill" : "calendar.badge.plus")
                    .foregroundStyle(.blue)
                Text(action.title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(action.editable) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        if field.multiline {
                            TextEditor(text: Binding(
                                get: { editedFields[field.id] ?? field.value },
                                set: { editedFields[field.id] = $0 }
                            ))
                            .font(.system(size: 13))
                            .frame(minHeight: 80, idealHeight: 120)
                            .padding(6)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            TextField(field.label, text: Binding(
                                get: { editedFields[field.id] ?? field.value },
                                set: { editedFields[field.id] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                        }
                    }
                }
            }

            HStack {
                Button(role: .cancel) {
                    // Dismiss the pending action by clearing the panel.
                    manager.hide()
                } label: {
                    Text(action.kind.contains(".send") ? "Verwerfen" : "Verwerfen")
                        .font(.system(size: 13))
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    // Merge edited values + unedited initial values.
                    var values: [String: String] = [:]
                    for field in action.editable {
                        values[field.key] = editedFields[field.id] ?? field.value
                    }
                    Task { await manager.confirmPending(action, editedValues: values) }
                } label: {
                    HStack(spacing: 6) {
                        if manager.isExecutingAction { ProgressView().scaleEffect(0.6) }
                        Image(systemName: action.kind.hasPrefix("gmail") ? "paperplane.fill" : "calendar.badge.checkmark")
                        Text(manager.isExecutingAction ? "…" : action.title)
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(manager.isExecutingAction)
            }
        }
        .padding(14)
        .background(Color.blue.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.blue.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Chat UI helpers

    @State private var chatDraft: String = ""

    private var chatInput: some View {
        HStack(spacing: 8) {
            TextField("Follow up — draft a reply, ask a question…", text: $chatDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(8)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onSubmit { sendChatDraft() }

            Button {
                sendChatDraft()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.borderless)
            .disabled(chatDraft.trimmingCharacters(in: .whitespaces).isEmpty || manager.isThinking)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func sendChatDraft() {
        let q = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        chatDraft = ""
        Task { await manager.sendFollowUp(q) }
    }

    @ViewBuilder
    private func chatBubble(_ turn: ChatTurn) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: turn.role == .user ? "person.circle.fill" : "sparkle")
                .font(.system(size: 14))
                .foregroundStyle(turn.role == .user ? .blue : .orange)
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                if let attr = try? AttributedString(markdown: turn.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                    Text(attr)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(turn.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if turn.role == .assistant {
                    HStack(spacing: 10) {
                        Button {
                            manager.copyTurn(turn)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func quickActions(for connectorId: String) -> some View {
        let presets: [(label: String, prompt: String)] = {
            switch connectorId {
            case "gmail":
                return [
                    ("📝 Draft a reply", "Draft a concise, polite reply to this email in the same language. Output only the email body."),
                    ("✂️ Summarize", "Summarize the most important points of this email in 2–3 bullet lines."),
                    ("🎯 Next action", "What's the single next action I need to take? Be concrete."),
                ]
            case "google_calendar":
                return [
                    ("📋 What's the day's agenda?", "Give me a 1-sentence summary of today's schedule — workload, gaps, key meetings."),
                    ("⏰ Find me a free slot", "Where are my longest free blocks today / this week?"),
                ]
            default:
                return []
            }
        }()
        if !presets.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.prompt) { preset in
                        Button {
                            Task { await manager.sendFollowUp(preset.prompt) }
                        } label: {
                            Text(preset.label)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(manager.isThinking)
                    }
                }
            }
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
            Text("Command Failed")
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
