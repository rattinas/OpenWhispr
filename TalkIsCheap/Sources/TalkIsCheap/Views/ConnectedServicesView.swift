import SwiftUI
import AppKit

struct ConnectedServicesView: View {
    @ObservedObject private var catalog = PipedreamCatalog.shared
    @ObservedObject private var shopify = ShopifyNativeClient.shared
    @State private var connectingApp: PipedreamClient.AppInfo?
    @State private var oauthError: String?
    @State private var isOAuthing = false
    @State private var showingGmailTriage = false
    @State private var showingShopifyAdd = false

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

            // Shopify — runs its own OAuth flow, not through Pipedream. Always
            // shown so the user has a clear entry point to add stores.
            Section {
                if shopify.connections.isEmpty {
                    Text("Connect the stores you want to query by revenue, orders, top products, etc.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shopify.connections) { conn in
                        shopifyStoreRow(conn)
                    }
                }
                Button {
                    showingShopifyAdd = true
                } label: {
                    Label("Add Shopify store", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                if let err = shopify.lastRefreshError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption2)
                }
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "cart.fill").foregroundStyle(.green)
                    Text("Shopify stores")
                    if shopify.isRefreshing {
                        ProgressView().scaleEffect(0.5)
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
        .task {
            if catalog.apps.isEmpty { await catalog.refresh() }
            if shopify.connections.isEmpty { await shopify.refresh() }
        }
        .sheet(item: Binding(
            get: { connectingApp.map { AppWrapper(app: $0) } },
            set: { connectingApp = $0?.app }
        )) { wrapper in
            connectSheet(app: wrapper.app)
        }
        .sheet(isPresented: $showingGmailTriage) {
            GmailTriageSettings()
        }
        .sheet(isPresented: $showingShopifyAdd) {
            ShopifyAddStoreSheet()
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
    private func shopifyStoreRow(_ conn: ShopifyNativeClient.Connection) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 149/255, green: 191/255, blue: 71/255).opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "cart.fill")
                    .foregroundStyle(Color(red: 149/255, green: 191/255, blue: 71/255))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(conn.shopHandle)
                    .font(.system(size: 13, weight: .medium))
                Text(conn.shopDomain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                Task {
                    do { try await shopify.disconnect(shop: conn.shopDomain) }
                    catch { oauthError = error.localizedDescription }
                }
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

// MARK: - Shopify add-store sheet

/// Asks for the shop handle, kicks off the backend install flow which opens
/// a browser, then auto-polls for the new connection to appear.
struct ShopifyAddStoreSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var shopify = ShopifyNativeClient.shared

    @State private var shopHandle: String = ""
    @State private var error: String?
    @State private var isOpening = false
    @State private var awaitingInstall = false
    @State private var pollTask: Task<Void, Never>?
    @State private var preExistingShopDomains: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(red: 149/255, green: 191/255, blue: 71/255).opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: "cart.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(red: 149/255, green: 191/255, blue: 71/255))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect a Shopify store")
                        .font(.headline)
                    Text("We open the install flow in your browser. Sign in, approve read access, and come back here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            // Body
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shop handle")
                        .font(.caption.bold())
                    TextField("mystore or mystore.myshopify.com", text: $shopHandle)
                        .textFieldStyle(.roundedBorder)
                        .disabled(awaitingInstall)
                    Text("The part before .myshopify.com — you can find it in your admin URL.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if awaitingInstall {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Waiting for you to approve the install…")
                                .font(.caption.bold())
                            Text("Complete the flow in your browser. This window will close automatically when the connection lands.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.blue.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if let err = error {
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

            // Footer
            HStack {
                Button("Cancel") {
                    pollTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if awaitingInstall {
                    Button {
                        Task { await shopify.refresh(); await detectLanded() }
                    } label: {
                        Label("Check now", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    Task { await startInstall() }
                } label: {
                    HStack(spacing: 8) {
                        if isOpening { ProgressView().scaleEffect(0.6) }
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .opacity(isOpening ? 0 : 1)
                        Text(awaitingInstall ? "Re-open browser" : "Open Shopify install")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isOpening || shopHandle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 540, height: 460)
        .onAppear {
            preExistingShopDomains = Set(shopify.connections.map(\.shopDomain))
        }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: - Actions

    private func startInstall() async {
        error = nil
        isOpening = true
        defer { isOpening = false }
        do {
            _ = try await shopify.startInstallFlow(forShop: shopHandle)
            awaitingInstall = true
            startPolling()
        } catch {
            self.error = (error as? ConnectorError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            // Poll every 3 seconds for up to 3 minutes. The callback on the
            // backend has already UPSERTed the token by the time the user
            // sees the success page, so the next refresh picks it up.
            for _ in 0..<60 {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                await shopify.refresh()
                await detectLanded()
                if !awaitingInstall { return }
            }
        }
    }

    @MainActor
    private func detectLanded() async {
        let current = Set(shopify.connections.map(\.shopDomain))
        if current.count > preExistingShopDomains.count
            || !current.subtracting(preExistingShopDomains).isEmpty {
            awaitingInstall = false
            pollTask?.cancel()
            dismiss()
        }
    }
}
