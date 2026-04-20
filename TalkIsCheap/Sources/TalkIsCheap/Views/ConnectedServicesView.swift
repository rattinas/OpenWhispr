import SwiftUI
import AppKit

struct ConnectedServicesView: View {
    @ObservedObject private var catalog = PipedreamCatalog.shared
    @State private var connectingApp: PipedreamClient.AppInfo?
    @State private var oauthError: String?
    @State private var isOAuthing = false
    @State private var showingGmailTriage = false

    var body: some View {
        Form {
            Section {
                Text("Connect your tools. When you use Command Mode (double-tap hotkey), TalkIsCheap detects which service you're asking about and answers from live data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("More services are on the way — we only enable them once we've verified the voice-query flow works end-to-end.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let err = catalog.loadError {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            if !catalog.accounts.isEmpty {
                Section {
                    ForEach(catalog.accounts, id: \.id) { account in
                        connectedRow(account)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Connected")
                    }
                }
            }

            let disconnected = availableApps()
            if !disconnected.isEmpty {
                Section {
                    ForEach(disconnected, id: \.slug) { app in
                        appRow(app)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("Available")
                    }
                } footer: {
                    HStack {
                        if catalog.isLoading {
                            ProgressView().scaleEffect(0.6)
                        }
                        Spacer()
                        Button {
                            Task { await catalog.refresh() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { if catalog.apps.isEmpty { await catalog.refresh() } }
        .sheet(item: Binding(
            get: { connectingApp.map { AppWrapper(app: $0) } },
            set: { connectingApp = $0?.app }
        )) { wrapper in
            connectSheet(app: wrapper.app)
        }
        .sheet(isPresented: $showingGmailTriage) {
            GmailTriageSettings()
        }
    }

    // MARK: - Lists

    private func connectedSlugs() -> Set<String> {
        Set(catalog.accounts.map { $0.appSlug.lowercased() })
    }

    /// Released apps that aren't yet connected.
    private func availableApps() -> [PipedreamClient.AppInfo] {
        let connected = connectedSlugs()
        return catalog.apps.filter { !connected.contains($0.slug.lowercased()) }
    }

    // MARK: - Rows

    @ViewBuilder
    private func connectedRow(_ account: PipedreamClient.Account) -> some View {
        HStack(spacing: 12) {
            appIcon(logo: account.appLogo)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.appName.isEmpty ? account.appSlug : account.appName)
                    .font(.system(size: 13, weight: .medium))
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            // Per-service settings entry point (currently: Gmail triage labels).
            if account.appSlug.lowercased() == "gmail" {
                Button {
                    showingGmailTriage = true
                } label: {
                    Image(systemName: "tag.circle")
                        .font(.system(size: 15))
                }
                .buttonStyle(.borderless)
                .help("Choose which labels the reply-triage agent should pick up")
            }
            Button(role: .destructive) {
                Task { await disconnect(account) }
            } label: {
                Text("Disconnect").font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func appRow(_ app: PipedreamClient.AppInfo) -> some View {
        HStack(spacing: 12) {
            appIcon(logo: app.logo)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                Text(app.categories.first?.capitalized ?? app.authType.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                oauthError = nil
                connectingApp = app
            } label: {
                Text("Connect").font(.system(size: 12))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func appIcon(logo: String?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 36, height: 36)
            if let logo, let url = URL(string: logo) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fit).padding(6)
                    default:
                        Image(systemName: "square.grid.2x2")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
    }

    // MARK: - Connect sheet

    private func connectSheet(app: PipedreamClient.AppInfo) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                appIcon(logo: app.logo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect \(app.name)")
                        .font(.headline)
                    Text("A browser window opens so you can sign in to \(app.name). No credentials pass through our servers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text("After you approve access, come back here — TalkIsCheap detects the new connection automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let err = oauthError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(24)

            Spacer()

            Divider()

            HStack {
                Button("Cancel") {
                    connectingApp = nil
                    oauthError = nil
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    Task { await startOAuth(app: app) }
                } label: {
                    HStack(spacing: 8) {
                        if isOAuthing { ProgressView().scaleEffect(0.6) }
                        Image(systemName: isOAuthing ? "" : "bolt.horizontal.circle.fill")
                            .opacity(isOAuthing ? 0 : 1)
                        Text(isOAuthing ? "Waiting for authorisation…" : "Open browser to authorise")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isOAuthing)
            }
            .padding(20)
        }
        .frame(width: 520, height: 440)
    }

    // MARK: - Actions

    private func startOAuth(app: PipedreamClient.AppInfo) async {
        isOAuthing = true
        oauthError = nil
        do {
            _ = try await PipedreamClient.shared.connect(app: app.slug)
            await catalog.refresh()
            connectingApp = nil
        } catch {
            oauthError = error.localizedDescription
        }
        isOAuthing = false
    }

    private func disconnect(_ account: PipedreamClient.Account) async {
        do {
            try await PipedreamClient.shared.disconnect(accountId: account.id)
            await catalog.refresh()
        } catch {
            oauthError = error.localizedDescription
        }
    }
}

private struct AppWrapper: Identifiable {
    let app: PipedreamClient.AppInfo
    var id: String { app.slug }
}
