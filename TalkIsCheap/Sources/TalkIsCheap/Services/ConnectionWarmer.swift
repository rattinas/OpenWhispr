import Foundation

/// Pre-warm HTTP connections to the APIs we hit during a dictation so the
/// first request doesn't pay the TLS handshake (200-400ms). URLSession reuses
/// these connections automatically as long as we use the same session.
enum ConnectionWarmer {
    /// Fire-and-forget warmup at app start.
    static func prewarm() {
        Task.detached(priority: .utility) {
            await warmHost("https://api.groq.com")
            await warmHost("https://api.anthropic.com")
            await warmHost("https://talkischeap.app")
        }
    }

    private static func warmHost(_ urlString: String) async {
        guard let url = URL(string: urlString) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: req)
    }
}
