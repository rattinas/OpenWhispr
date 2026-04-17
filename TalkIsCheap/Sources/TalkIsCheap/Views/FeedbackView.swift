import SwiftUI
import AppKit

/// In-app feedback form that sends feature requests, bug reports, or love letters to Bene.
/// POSTs to https://talkischeap.app/api/feedback
struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared

    @State private var category: Category = .feature
    @State private var message: String = ""
    @State private var email: String = ""
    @State private var isSending = false
    @State private var sendStatus: SendStatus = .idle

    enum Category: String, CaseIterable, Identifiable {
        case feature, bug, general, love
        var id: String { rawValue }
        var emoji: String {
            switch self {
            case .feature: return "✨"
            case .bug: return "🐛"
            case .general: return "💬"
            case .love: return "❤️"
            }
        }
        var title: String {
            switch self {
            case .feature: return "Feature Request"
            case .bug: return "Bug Report"
            case .general: return "General Feedback"
            case .love: return "Love Letter"
            }
        }
        var placeholder: String {
            switch self {
            case .feature: return "I'd love to be able to..."
            case .bug: return "When I do X, Y happens, but I expected Z..."
            case .general: return "I've been thinking about..."
            case .love: return "TalkIsCheap has changed my life because..."
            }
        }
    }

    enum SendStatus: Equatable {
        case idle
        case success
        case error(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(.blue)
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text("Send Feedback").font(.headline)
                    Text("Your message goes straight to the developer")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            // Category picker
            Picker("What kind of feedback?", selection: $category) {
                ForEach(Category.allCases) { cat in
                    Text("\(cat.emoji) \(cat.title)").tag(cat)
                }
            }
            .pickerStyle(.segmented)

            // Email (pre-filled from license if available)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your email (optional — but helps us reply)")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            // Message
            VStack(alignment: .leading, spacing: 4) {
                Text("Your message")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $message)
                    .font(.system(.body))
                    .frame(height: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if message.isEmpty {
                            Text(category.placeholder)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }
                    }
                HStack {
                    Spacer()
                    Text("\(message.count) / 5000")
                        .font(.caption2)
                        .foregroundStyle(message.count > 4500 ? Color.orange : Color.secondary.opacity(0.6))
                }
            }

            // Status
            if case .success = sendStatus {
                Label("Thanks — your feedback has arrived!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
            if case .error(let msg) = sendStatus {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            // Buttons
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    Task { await send() }
                } label: {
                    HStack {
                        if isSending {
                            ProgressView().scaleEffect(0.6)
                        }
                        Text(isSending ? "Sending…" : "Send Feedback")
                    }
                    .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isSending ||
                    message.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 ||
                    message.count > 5000
                )
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            // Pre-fill email from license if we have one
            if email.isEmpty, !settings.licenseKey.isEmpty {
                email = (settings.licenseKey as NSString)
                    .substring(to: min(40, settings.licenseKey.count)) == "" ? "" : email
            }
        }
    }

    private func send() async {
        isSending = true
        sendStatus = .idle

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        let payload: [String: Any] = [
            "category": category.rawValue,
            "message": message.trimmingCharacters(in: .whitespacesAndNewlines),
            "email": email.trimmingCharacters(in: .whitespaces),
            "license_key": settings.licenseKey,
            "app_version": appVersion,
            "os_version": osVersion,
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: "https://talkischeap.app/api/feedback") else {
            sendStatus = .error("Failed to build request")
            isSending = false
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                sendStatus = .success
                message = ""
                // Auto-close after 2 seconds
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                dismiss()
            } else {
                sendStatus = .error("Server returned an error. Try again later.")
            }
        } catch {
            sendStatus = .error("Network error. Check your connection.")
        }

        isSending = false
    }
}
