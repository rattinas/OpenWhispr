import SwiftUI
import AppKit

struct ConnectedServicesView: View {
    @ObservedObject private var catalog = NangoCatalog.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var connectingTo: NangoClient.CatalogEntry?
    @State private var oauthError: String?
    @State private var isOAuthing = false
    @State private var search = ""

    private var activePack: IndustryPack? {
        guard !settings.industryPack.isEmpty else { return nil }
        return IndustryPack.all.first { $0.id == settings.industryPack }
    }

    var body: some View {
        Form {
            Section {
                Text("Connect your tools via one-click OAuth. When you use Command Mode (double-tap hotkey), TalkIsCheap detects which service you're asking about and answers from live data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                industryPickerRow

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter services…", text: $search)
                        .textFieldStyle(.plain)
                    if catalog.isLoading {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Button {
                            Task { await catalog.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh list from Nango")
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

            if catalog.entries.isEmpty && !catalog.isLoading {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No integrations configured yet.")
                            .font(.system(size: 13, weight: .medium))
                        Text("Add integrations in your Nango dashboard at app.nango.dev — they'll show up here automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Link("Open Nango Dashboard", destination: URL(string: "https://app.nango.dev")!)
                            .font(.caption)
                    }
                }
            } else {
                // Industry-prioritised "Recommended for you" section when a pack is picked.
                if let pack = activePack {
                    let recommended = entriesForPack(pack)
                    if !recommended.isEmpty {
                        Section {
                            ForEach(recommended, id: \.uniqueKey) { entry in
                                row(entry, highlight: true)
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

                // All other services, grouped by category.
                ForEach(filteredGroups(), id: \.0) { cat, list in
                    Section {
                        ForEach(list, id: \.uniqueKey) { entry in
                            row(entry)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: NangoCategoryDisplay.icon(cat))
                            Text(NangoCategoryDisplay.label(cat))
                        }
                    }
                }

                // Browse all 761 Nango providers. Each row opens Nango's
                // dashboard at the right integration-create page.
                let browseList = filteredProviders()
                if !browseList.isEmpty {
                    Section {
                        ForEach(browseList.prefix(40), id: \.name) { p in
                            browseRow(p)
                        }
                        if browseList.count > 40 {
                            Text("\(browseList.count - 40) more matching — type in the search box to narrow down.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.grid.3x3.fill")
                            Text("Add more services")
                        }
                    } footer: {
                        Text("Pick a service → we open Nango's dashboard with the provider pre-selected. Complete the 30-second setup (Nango uses shared OAuth for most), then come back and refresh.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { if catalog.entries.isEmpty { await catalog.refresh() } }
        .sheet(item: Binding(
            get: { connectingTo.map { EntryWrapper(entry: $0) } },
            set: { connectingTo = $0?.entry }
        )) { wrapper in
            connectSheet(entry: wrapper.entry)
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

    /// Filter entries that belong to this pack (by Nango provider name) —
    /// and sort them by the pack's suggested priority order.
    private func entriesForPack(_ pack: IndustryPack) -> [NangoClient.CatalogEntry] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = catalog.entries.compactMap { entry -> (Int, NangoClient.CatalogEntry)? in
            guard let pos = pack.priority(for: entry.provider) else { return nil }
            if !needle.isEmpty, !entry.displayName.lowercased().contains(needle),
               !entry.provider.lowercased().contains(needle) {
                return nil
            }
            return (pos, entry)
        }
        return matched.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    /// All Nango providers the user hasn't configured yet, filtered by
    /// search + active industry pack if one is chosen. Pack-matching
    /// providers float to the top.
    private func filteredProviders() -> [NangoClient.ProviderInfo] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var candidates = catalog.unconfiguredProviders()
        if !needle.isEmpty {
            candidates = candidates.filter {
                $0.displayName.lowercased().contains(needle)
                    || $0.name.lowercased().contains(needle)
                    || $0.categories.contains(where: { $0.lowercased().contains(needle) })
            }
        }

        // Sort: pack-matching providers first (by pack priority), then alphabetical.
        if let pack = activePack {
            return candidates.sorted { a, b in
                let pa = pack.priority(for: a.name) ?? Int.max
                let pb = pack.priority(for: b.name) ?? Int.max
                if pa != pb { return pa < pb }
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
        }
        return candidates
    }

    @ViewBuilder
    private func browseRow(_ provider: NangoClient.ProviderInfo) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 36, height: 36)
                if let logo = provider.logoUrl, let url = URL(string: logo) {
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
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(provider.categories.first?.capitalized ?? provider.authMode.lowercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                openNangoSetup(provider: provider)
            } label: {
                Text("Set up in Nango")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func openNangoSetup(provider: NangoClient.ProviderInfo) {
        // Deep-link into Nango's integration-create form with the provider
        // pre-selected. Falls back to the generic integrations page if
        // the deep link isn't recognised.
        let url = URL(string: "https://app.nango.dev/prod/integrations/new?provider=\(provider.name)")
            ?? URL(string: "https://app.nango.dev/prod/integrations")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Rows

    private func filteredGroups() -> [(String, [NangoClient.CatalogEntry])] {
        let groups = catalog.grouped()
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { cat, list in
            let filtered = list.filter {
                $0.displayName.lowercased().contains(needle)
                    || $0.provider.lowercased().contains(needle)
                    || $0.uniqueKey.lowercased().contains(needle)
            }
            return filtered.isEmpty ? nil : (cat, filtered)
        }
    }

    @ViewBuilder
    private func row(_ entry: NangoClient.CatalogEntry, highlight: Bool = false) -> some View {
        HStack(spacing: 12) {
            integrationIcon(entry)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.system(size: 13, weight: highlight ? .semibold : .medium))
                if entry.connected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text(entry.provider)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if entry.connected {
                Button(role: .destructive) {
                    Task { await disconnect(entry) }
                } label: {
                    Text("Disconnect")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button {
                    oauthError = nil
                    connectingTo = entry
                } label: {
                    Text("Connect")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func integrationIcon(_ entry: NangoClient.CatalogEntry) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 36, height: 36)
            if let logo = entry.logo, let url = URL(string: logo) {
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
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
    }

    // MARK: - Connect sheet

    private func connectSheet(entry: NangoClient.CatalogEntry) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                integrationIcon(entry)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect \(entry.displayName)")
                        .font(.headline)
                    Text("You authorise TalkIsCheap to read your data through your \(entry.provider) account. Nothing is stored on our side other than the Nango connection ID.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text("A browser window will open so you can sign in to \(entry.provider). After you approve access, come back here — TalkIsCheap will detect the new connection automatically.")
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
                    connectingTo = nil
                    oauthError = nil
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    Task { await startOAuth(entry: entry) }
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

    private func startOAuth(entry: NangoClient.CatalogEntry) async {
        isOAuthing = true
        oauthError = nil
        do {
            _ = try await NangoClient.shared.connect(integrationKey: entry.uniqueKey)
            await catalog.refresh()
            connectingTo = nil
        } catch {
            oauthError = error.localizedDescription
        }
        isOAuthing = false
    }

    private func disconnect(_ entry: NangoClient.CatalogEntry) async {
        guard let connectionId = entry.connectionId else { return }
        do {
            try await NangoClient.shared.disconnect(
                integrationKey: entry.uniqueKey,
                connectionId: connectionId
            )
            await catalog.refresh()
        } catch {
            oauthError = error.localizedDescription
        }
    }
}

private struct EntryWrapper: Identifiable {
    let entry: NangoClient.CatalogEntry
    var id: String { entry.uniqueKey }
}
