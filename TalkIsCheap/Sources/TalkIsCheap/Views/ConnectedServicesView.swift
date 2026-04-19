import SwiftUI

struct ConnectedServicesView: View {
    @ObservedObject private var registry = ConnectorRegistry.shared
    @State private var connectingTo: ConnectorWrapper?
    @State private var connectError: String?
    @State private var isConnecting = false
    @State private var credentials: [String: String] = [:]

    var body: some View {
        Form {
            Section {
                Text("Connect your business tools. When you do a voice search, TalkIsCheap automatically detects which service to query based on what you say — no mode switching needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Available Services") {
                ForEach(registry.allConnectors, id: \.id) { connector in
                    connectorRow(connector)
                }
            }

            if !registry.connectedConnectors.isEmpty {
                Section {
                    Button {
                        registry.clearCache()
                    } label: {
                        Label("Clear Data Cache", systemImage: "arrow.triangle.2.circlepath")
                    }
                } footer: {
                    Text("Query results are cached for 15 minutes. Clear if you need fresh data right now.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $connectingTo) { wrapper in
            connectSheet(connector: wrapper.connector)
        }
    }

    // MARK: - Connector Row

    @ViewBuilder
    private func connectorRow(_ connector: any Connector) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: connector.accentColorHex).opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: connector.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(hex: connector.accentColorHex))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(connector.name)
                    .font(.system(size: 13, weight: .medium))
                if connector.isConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("Not connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if connector.isConnected {
                Button(role: .destructive) {
                    registry.disconnect(connector: connector)
                } label: {
                    Text("Disconnect")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button {
                    credentials = [:]
                    connectError = nil
                    connectingTo = ConnectorWrapper(connector: connector)
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

    // MARK: - Connect Sheet

    private func connectSheet(connector: any Connector) -> some View {
        VStack(spacing: 20) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(hex: connector.accentColorHex).opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: connector.icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color(hex: connector.accentColorHex))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect \(connector.name)")
                        .font(.headline)
                    Text("Stored securely in your Keychain — never sent to our servers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            // Credential fields
            VStack(spacing: 12) {
                ForEach(connector.credentialFields, id: \.key) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        if field.isSecret {
                            SecureField(field.key, text: credentialBinding(for: field.key))
                                .textFieldStyle(.roundedBorder)
                        } else {
                            TextField(field.key, text: credentialBinding(for: field.key))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }

            // Per-connector help
            connectorHelp(connector)

            if let error = connectError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    connectingTo = nil
                    connectError = nil
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    guard let wrapper = connectingTo else { return }
                    performConnect(connector: wrapper.connector)
                } label: {
                    HStack(spacing: 6) {
                        if isConnecting { ProgressView().scaleEffect(0.6) }
                        Text(isConnecting ? "Connecting…" : "Connect")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isConnecting || !hasRequiredFields(connector))
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    @ViewBuilder
    private func connectorHelp(_ connector: any Connector) -> some View {
        switch connector.id {
        case "shopify":
            helpBox(
                "Admin → Settings → Apps and sales channels → Develop apps → Create an app → API credentials",
                url: "https://help.shopify.com/en/manual/apps/app-types/private-apps"
            )
        case "stripe":
            helpBox(
                "Dashboard → Developers → API keys. Use your live secret key (sk_live_...) for real data.",
                url: "https://dashboard.stripe.com/apikeys"
            )
        case "github":
            helpBox(
                "GitHub → Settings → Developer settings → Personal access tokens. Needs repo scope.",
                url: "https://github.com/settings/tokens/new"
            )
        case "ga4":
            helpBox(
                "Google Cloud → IAM → Service Accounts → Create → Download JSON key. Grant 'Viewer' in your GA4 property settings.",
                url: "https://console.cloud.google.com/iam-admin/serviceaccounts"
            )
        default:
            EmptyView()
        }
    }

    private func helpBox(_ text: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let u = URL(string: url) {
                Link("Open instructions →", destination: u)
                    .font(.caption)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    private func credentialBinding(for key: String) -> Binding<String> {
        Binding(
            get: { credentials[key] ?? "" },
            set: { credentials[key] = $0 }
        )
    }

    private func hasRequiredFields(_ connector: any Connector) -> Bool {
        connector.credentialFields
            .filter { !$0.label.lowercased().contains("optional") }
            .allSatisfy { !(credentials[$0.key] ?? "").isEmpty }
    }

    private func performConnect(connector: any Connector) {
        isConnecting = true
        connectError = nil
        Task {
            do {
                // 1. Shape-check + Keychain store
                try registry.connect(connector: connector, credentials: credentials)

                // 2. Live ping so bad credentials surface here instead of
                //    on the user's first voice query. Disconnect again if
                //    the test call fails, so we don't leave half-broken
                //    state in the Keychain.
                do {
                    try await connector.testConnection()
                } catch {
                    registry.disconnect(connector: connector)
                    throw error
                }

                await MainActor.run {
                    connectingTo = nil
                    isConnecting = false
                }
            } catch {
                await MainActor.run {
                    connectError = error.localizedDescription
                    isConnecting = false
                }
            }
        }
    }
}

// MARK: - Identifiable wrapper for sheet binding

private struct ConnectorWrapper: Identifiable {
    let connector: any Connector
    var id: String { connector.id }
}

// MARK: - Color from hex string

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        self.init(
            red: Double((int >> 16) & 0xFF) / 255,
            green: Double((int >> 8) & 0xFF) / 255,
            blue: Double(int & 0xFF) / 255
        )
    }
}
