import SwiftUI
import AppKit

struct ConnectedServicesView: View {
    @ObservedObject private var registry = ConnectorRegistry.shared
    @State private var connectingTo: ConnectorWrapper?
    @State private var connectError: String?
    @State private var isConnecting = false
    @State private var isOAuthing = false
    @State private var credentials: [String: String] = [:]
    @State private var guideExpanded = false
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Section {
                Text("Connect your tools. When you use Command Mode (double-tap hotkey), TalkIsCheap detects which service your query is about and answers from live data — no mode switching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Grouped by category (Mode)
            ForEach(registry.connectorsByCategory(), id: \.0) { cat, connectors in
                Section {
                    ForEach(connectors, id: \.id) { connector in
                        connectorRow(connector)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: cat.icon)
                        Text(cat.label)
                    }
                } footer: {
                    Text(cat.subtitle).font(.caption).foregroundStyle(.secondary)
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
                    guideExpanded = true
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
        VStack(spacing: 0) {
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
                    Text("Credentials stored in your Mac's Keychain — never sent to our servers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // ── Primary path: Managed OAuth via Nango ─────────────
                    if connector.nangoIntegrationKey != nil {
                        nangoOAuthSection(connector)
                    }

                    // ── Advanced / fallback: paste credentials manually ──
                    if connector.nangoIntegrationKey != nil {
                        DisclosureGroup(isExpanded: $showAdvanced) {
                            pasteCredentialsBlock(connector)
                                .padding(.top, 10)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "wrench.adjustable")
                                    .font(.system(size: 11))
                                Text("Advanced: connect with manual credentials")
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                            }
                            .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .background(Color.secondary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        // No Nango integration for this connector — paste is the only path.
                        pasteCredentialsBlock(connector)
                    }

                    if let error = connectError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(24)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    connectingTo = nil
                    connectError = nil
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                // Paste-credentials button is only shown when the advanced
                // section is open (or when Nango isn't available at all).
                let showPasteButton = connector.nangoIntegrationKey == nil || showAdvanced
                if showPasteButton {
                    Button {
                        guard let wrapper = connectingTo else { return }
                        performConnect(connector: wrapper.connector)
                    } label: {
                        HStack(spacing: 6) {
                            if isConnecting { ProgressView().scaleEffect(0.6) }
                            Text(isConnecting ? "Testing…" : "Connect with credentials")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isConnecting || isOAuthing || !hasRequiredFields(connector))
                }
            }
            .padding(20)
        }
        .frame(width: 520, height: 640)
    }

    @ViewBuilder
    private func nangoOAuthSection(_ connector: any Connector) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .foregroundStyle(Color(hex: connector.accentColorHex))
                Text("Connect with one click")
                    .font(.system(size: 14, weight: .semibold))
            }
            Text("Opens the \(connector.name) login page. You authorise TalkIsCheap to read your data through **Nango** — no tokens to copy.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                guard let wrapper = connectingTo else { return }
                performOAuth(connector: wrapper.connector)
            } label: {
                HStack(spacing: 8) {
                    if isOAuthing { ProgressView().scaleEffect(0.6) }
                    Image(systemName: isOAuthing ? "" : connector.icon)
                        .opacity(isOAuthing ? 0 : 1)
                    Text(isOAuthing ? "Waiting for authorisation…" : "Connect \(connector.name)")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: connector.accentColorHex))
            .disabled(isOAuthing || isConnecting)
        }
        .padding(16)
        .background(Color(hex: connector.accentColorHex).opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: connector.accentColorHex).opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func pasteCredentialsBlock(_ connector: any Connector) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !connector.setupGuide.isEmpty {
                setupGuideSection(connector)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Paste your credentials")
                    .font(.system(size: 13, weight: .semibold))
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
        }
    }

    // MARK: - Setup guide block

    @ViewBuilder
    private func setupGuideSection(_ connector: any Connector) -> some View {
        DisclosureGroup(isExpanded: $guideExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(connector.setupGuide.enumerated()), id: \.offset) { _, step in
                    setupStepView(step)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "list.number")
                    .foregroundStyle(Color(hex: connector.accentColorHex))
                Text("Setup guide")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func setupStepView(_ step: SetupStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(step.title)
                .font(.system(size: 13, weight: .semibold))

            if let detail = step.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let url = step.actionURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10))
                        Text(step.actionLabel ?? url.absoluteString)
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
            }

            if let copy = step.copyable {
                HStack(alignment: .top, spacing: 8) {
                    Text(copy)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copy, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
                .padding(8)
                .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.leading, 4)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(hex: "#cccccc").opacity(0.5))
                .frame(width: 2)
                .offset(x: -6)
        }
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

    private func performOAuth(connector: any Connector) {
        guard let integrationKey = connector.nangoIntegrationKey else { return }
        isOAuthing = true
        connectError = nil
        Task {
            do {
                let connectionId = try await NangoClient.shared.connect(integrationKey: integrationKey)
                try registry.connect(
                    connector: connector,
                    credentials: ["nangoConnectionId": connectionId]
                )
                // Run testConnection to verify the Nango proxy actually works
                // for this connection — catches cases where the OAuth flow
                // "completed" but the token doesn't have the needed scopes.
                do {
                    try await connector.testConnection()
                } catch {
                    try? await NangoClient.shared.disconnect(
                        integrationKey: integrationKey,
                        connectionId: connectionId
                    )
                    registry.disconnect(connector: connector)
                    throw error
                }
                await MainActor.run {
                    connectingTo = nil
                    isOAuthing = false
                }
            } catch {
                await MainActor.run {
                    connectError = error.localizedDescription
                    isOAuthing = false
                }
            }
        }
    }

    private func performConnect(connector: any Connector) {
        isConnecting = true
        connectError = nil
        Task {
            do {
                // 1. Shape-check + Keychain store
                try registry.connect(connector: connector, credentials: credentials)

                // 2. Live ping so bad credentials surface here, not on the
                //    user's first voice query. Disconnect again if the test
                //    fails so we don't leave half-broken state in Keychain.
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

// MARK: - Hashable conformance for ForEach binding on ConnectorCategory

extension ConnectorCategory: Hashable {}
