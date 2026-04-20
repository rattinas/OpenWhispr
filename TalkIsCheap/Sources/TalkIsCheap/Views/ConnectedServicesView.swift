import SwiftUI
import AppKit

struct ConnectedServicesView: View {
    @ObservedObject private var catalog = PipedreamCatalog.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var connectingApp: PipedreamClient.AppInfo?
    @State private var oauthError: String?
    @State private var isOAuthing = false
    @State private var search = ""
    @State private var searchTask: Task<Void, Never>?

    private var activePack: IndustryPack? {
        guard !settings.industryPack.isEmpty else { return nil }
        return IndustryPack.all.first { $0.id == settings.industryPack }
    }

    var body: some View {
        Form {
            Section {
                Text("Connect any of your business tools. When you use Command Mode (double-tap hotkey), TalkIsCheap asks the right service and answers from live data. All OAuth is managed — no tokens to copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                industryPickerRow

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search any of 3000+ apps…", text: $search)
                        .textFieldStyle(.plain)
                        .onChange(of: search) { _, newValue in
                            // Debounce: wait 300ms after typing stops,
                            // then hit Pipedream's live search.
                            searchTask?.cancel()
                            searchTask = Task {
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                if Task.isCancelled { return }
                                await catalog.search(newValue)
                            }
                        }
                    if catalog.isLoading {
                        ProgressView().scaleEffect(0.6)
                    } else if !search.isEmpty {
                        Button {
                            search = ""
                            searchTask?.cancel()
                            Task { await catalog.refresh() }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Clear")
                    } else {
                        Button {
                            Task { await catalog.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh")
                    }
                }
                .padding(6)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                if let err = catalog.loadError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            // Connected accounts first — always shown.
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

            let searchActive = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if searchActive {
                // Flat list of server-returned search results — no category
                // buckets, no local filter, no pack priority. User typed
                // something, show them exactly what Pipedream matched.
                Section {
                    let connected = connectedSlugs()
                    let results = catalog.apps.filter { !connected.contains($0.slug.lowercased()) }
                    if results.isEmpty && !catalog.isLoading {
                        Text("No apps matching \"\(search)\".")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(results, id: \.slug) { app in
                        appRow(app)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                        Text("Search results")
                    }
                }
            } else {
                // "Recommended for <industry>" when a pack is selected.
                if let pack = activePack {
                    let recommended = appsForPack(pack)
                    if !recommended.isEmpty {
                        Section {
                            ForEach(recommended.prefix(25), id: \.slug) { app in
                                appRow(app, highlight: true)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Text(pack.emoji)
                                Text("Recommended for \(pack.name)")
                            }
                        } footer: {
                            Text(pack.tagline).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                // All curated apps grouped by category.
                ForEach(groupedApps(), id: \.0) { cat, list in
                    Section {
                        ForEach(list.prefix(30), id: \.slug) { app in
                            appRow(app)
                        }
                        if list.count > 30 {
                            Text("\(list.count - 30) more — type in the search box above.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: NangoCategoryDisplay.icon(cat))
                            Text(NangoCategoryDisplay.label(cat))
                        }
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
    }

    // MARK: - Industry picker

    @ViewBuilder
    private var industryPickerRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                industryChip(id: "", emoji: "🌐", label: "All", tagline: "Browse every service")
                ForEach(IndustryPack.all) { pack in
                    industryChip(id: pack.id, emoji: pack.emoji, label: pack.name, tagline: pack.tagline)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func industryChip(id: String, emoji: String, label: String, tagline: String) -> some View {
        let isActive = settings.industryPack == id
        Button {
            settings.industryPack = id
        } label: {
            HStack(spacing: 6) {
                Text(emoji)
                Text(label)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(tagline)
    }

    // MARK: - Filtering

    private func matchesSearch(_ app: PipedreamClient.AppInfo) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty { return true }
        return app.name.lowercased().contains(needle)
            || app.slug.lowercased().contains(needle)
            || app.categories.contains { $0.lowercased().contains(needle) }
    }

    private func connectedSlugs() -> Set<String> {
        Set(catalog.accounts.map { $0.appSlug.lowercased() })
    }

    private func appsForPack(_ pack: IndustryPack) -> [PipedreamClient.AppInfo] {
        let connected = connectedSlugs()
        let matched: [(Int, PipedreamClient.AppInfo)] = catalog.apps.compactMap { app in
            guard matchesSearch(app) else { return nil }
            if connected.contains(app.slug.lowercased()) { return nil }
            guard let pos = pack.priority(for: app.slug) else { return nil }
            return (pos, app)
        }
        return matched.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    private func groupedApps() -> [(String, [PipedreamClient.AppInfo])] {
        let connected = connectedSlugs()
        var buckets: [String: [PipedreamClient.AppInfo]] = [:]
        for app in catalog.apps where matchesSearch(app) {
            if connected.contains(app.slug.lowercased()) { continue }
            buckets[catalog.category(for: app), default: []].append(app)
        }
        let order = ["ecommerce", "marketing", "dev", "recruiting", "productivity", "other"]
        return order.compactMap { cat in
            guard let list = buckets[cat], !list.isEmpty else { return nil }
            return (cat, list)
        }
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
    private func appRow(_ app: PipedreamClient.AppInfo, highlight: Bool = false) -> some View {
        HStack(spacing: 12) {
            appIcon(logo: app.logo)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 13, weight: highlight ? .semibold : .medium))
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
