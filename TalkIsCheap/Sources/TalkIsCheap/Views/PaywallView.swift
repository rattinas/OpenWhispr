import SwiftUI

struct PaywallView: View {
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("You've used all \(TRIAL_USES_LIMIT) free uses!")
                .font(.title2.bold())

            Text("Pick how you want to continue:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                // Pro Monthly — hero option
                optionButton(
                    title: "Pro Monthly — $9.99/mo",
                    subtitle: "Zero setup. We handle API keys. 5000 dictations/mo.",
                    color: .blue,
                    badge: "RECOMMENDED",
                    action: {
                        Task { await startSubscriptionCheckout(plan: "monthly") }
                    }
                )

                // Pro Annual
                optionButton(
                    title: "Pro Annual — $79/yr",
                    subtitle: "Save 34% — same as Monthly but 2 months free.",
                    color: .purple,
                    badge: "BEST VALUE",
                    action: {
                        Task { await startSubscriptionCheckout(plan: "annual") }
                    }
                )

                // Lifetime — for tech users
                optionButton(
                    title: "Lifetime — $19 (one-time)",
                    subtitle: "Bring your own API keys. Unlimited, forever.",
                    color: Color(red: 0.91, green: 0.38, blue: 0.30),
                    action: {
                        openBrowser("https://talkischeap.app/checkout")
                    }
                )

                // BYOK Free
                optionButton(
                    title: "Bring Your Own API Keys (Free)",
                    subtitle: "Enter Groq + Anthropic keys. Unlimited uses, you pay the APIs directly.",
                    color: .gray,
                    action: {
                        settings.tier = ""
                        settings.useCloudProxy = false
                        settings.paywallDismissed = true
                        dismiss()
                        NotificationCenter.default.post(name: .openSettings, object: nil)
                    }
                )

                // Offline
                optionButton(
                    title: "Use Offline Mode (Free)",
                    subtitle: "Install mlx-whisper + Ollama locally. 100% private, no internet needed.",
                    color: .green,
                    action: {
                        settings.sttProvider = "local"
                        settings.polishProvider = "ollama"
                        settings.useCloudProxy = false
                        settings.paywallDismissed = true
                        dismiss()
                        NotificationCenter.default.post(name: .startLocalSetup, object: nil)
                    }
                )
            }

            Spacer(minLength: 8)

            Button("Not now — remind me later") {
                settings.paywallDismissed = true
                dismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
        }
        .padding(32)
        .frame(width: 500, height: 620)
    }

    private func optionButton(title: String, subtitle: String, color: Color, badge: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.subheadline.weight(.semibold))
                        if let badge {
                            Text(badge)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(color)
                                .clipShape(Capsule())
                        }
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(color)
                    .font(.title3)
            }
            .padding(12)
            .background(color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(color.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func openBrowser(_ url: String) {
        if let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
    }

    private func startSubscriptionCheckout(plan: String) async {
        let hwid = LicenseManager.hardwareUUID()
        var request = URLRequest(url: URL(string: "https://talkischeap.app/api/create-subscription-checkout")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "plan": plan,
            "hardwareId": hwid,
        ])

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let urlStr = json["url"] as? String {
                openBrowser(urlStr)
            }
        } catch {
            Log.write("Subscription checkout failed: \(error)")
        }
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("TalkIsCheap.openSettings")
    static let startLocalSetup = Notification.Name("TalkIsCheap.startLocalSetup")
    static let showPaywall = Notification.Name("TalkIsCheap.showPaywall")
}
