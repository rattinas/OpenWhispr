import SwiftUI

/// Lets the user pick which of THEIR Gmail labels should drive the
/// "needs reply" triage. Fetches labels live from Gmail (via Pipedream
/// proxy) when opened, so the list is always fresh.
struct GmailTriageSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    struct GmailLabel: Identifiable, Hashable {
        let id: String
        let name: String
        let isUser: Bool   // false = system label (INBOX, STARRED, …)
    }

    @State private var labels: [GmailLabel] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "envelope.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gmail Triage Labels")
                        .font(.headline)
                    Text("Pick the labels the agent should treat as \"needs my reply\". Leave empty to use automatic detection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Group {
                if isLoading {
                    VStack { ProgressView("Loading labels…") }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = errorMessage {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Button("Retry") { Task { await load() } }
                            .buttonStyle(.bordered)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if labels.isEmpty {
                    VStack {
                        Text("No labels found.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            let userLabels = labels.filter { $0.isUser }
                            if !userLabels.isEmpty {
                                section("Your labels", items: userLabels)
                            }
                            let systemLabels = labels.filter { !$0.isUser }
                            if !systemLabels.isEmpty {
                                Divider().padding(.vertical, 8)
                                section("System labels", items: systemLabels)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }
                }
            }
            .frame(minHeight: 320)

            Divider()

            HStack {
                Button("Select none") { selected = [] }
                    .disabled(selected.isEmpty)
                Button("Auto-detect") {
                    // Pre-fill with the built-in keyword heuristic.
                    let hints = ["answer","reply","respond","urgent","action","todo","to-do","to do","follow up","follow-up","followup","wait","waiting","antwort","beantwort","wichtig","dringend","aufgabe","erledig","rückmeld","priority","priorität"]
                    selected = Set(labels.filter { $0.isUser && hints.contains(where: { $0.lowercased().contains($0) == false ? false : true }) }.map { $0.name })
                    // Fix: filter by name containing any hint.
                    selected = Set(labels.compactMap { label in
                        guard label.isUser else { return nil }
                        let n = label.name.lowercased()
                        return hints.contains(where: { n.contains($0) }) ? label.name : nil
                    })
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    settings.gmailTriageLabelList = Array(selected).sorted()
                    dismiss()
                } label: {
                    Text("Save  \(selected.isEmpty ? "" : "(\(selected.count))")")
                        .frame(minWidth: 80)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
        .task { await load() }
    }

    @ViewBuilder
    private func section(_ title: String, items: [GmailLabel]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
            ForEach(items) { label in
                HStack {
                    Toggle(label.name, isOn: Binding(
                        get: { selected.contains(label.name) },
                        set: { on in
                            if on { selected.insert(label.name) }
                            else { selected.remove(label.name) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        // Get the connected Gmail account via PipedreamCatalog.
        await PipedreamCatalog.shared.ensureAccountsLoaded()
        guard let account = PipedreamCatalog.shared.account(forApp: "gmail") else {
            errorMessage = "Gmail isn't connected — connect it in Services first."
            isLoading = false
            return
        }

        do {
            let data = try await PipedreamClient.shared.proxy(
                accountId: account.id,
                url: "https://gmail.googleapis.com/gmail/v1/users/me/labels",
                method: "GET"
            )
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = json["labels"] as? [[String: Any]] else {
                errorMessage = "Could not parse Gmail label list"
                isLoading = false
                return
            }
            let parsed: [GmailLabel] = raw.compactMap { dict in
                guard let id = dict["id"] as? String,
                      let name = dict["name"] as? String else { return nil }
                let type = (dict["type"] as? String) ?? "user"
                return GmailLabel(id: id, name: name, isUser: type == "user")
            }
            .sorted { lhs, rhs in
                if lhs.isUser != rhs.isUser { return lhs.isUser && !rhs.isUser }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            self.labels = parsed
            self.selected = Set(settings.gmailTriageLabelList)
        } catch {
            errorMessage = "Failed to load: \(error.localizedDescription)"
        }
        isLoading = false
    }
}
