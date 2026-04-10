import Foundation
import AppKit

/// Checks for app updates by fetching latest.json from the website
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var updateAvailable = false
    @Published var latestVersion = ""
    @Published var downloadURL = ""
    @Published var releaseNotes = ""

    private let updateURL = "https://talkischeap.app/latest.json"
    private let currentVersion = AppSettings.currentVersion

    func checkForUpdate() {
        // Only check once per day
        let lastCheck = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        let now = Date().timeIntervalSince1970
        if now - lastCheck < 86400 { // 24 hours
            Log.write("Update check: skipped (checked recently)")
            return
        }

        Task {
            await performCheck()
            UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
        }
    }

    /// Force check (from menu button)
    func forceCheck() {
        Task { await performCheck() }
    }

    private func performCheck() async {
        guard let url = URL(string: updateURL) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String,
                  let download = json["downloadURL"] as? String
            else {
                Log.write("Update check: invalid JSON")
                return
            }

            let notes = json["notes"] as? String ?? ""

            if isNewer(version, than: currentVersion) {
                latestVersion = version
                downloadURL = download
                releaseNotes = notes
                updateAvailable = true
                Log.write("Update available: \(version) (current: \(currentVersion))")
            } else {
                updateAvailable = false
                Log.write("Up to date: \(currentVersion)")
            }
        } catch {
            Log.write("Update check failed: \(error)")
        }
    }

    func openDownloadPage() {
        if let url = URL(string: downloadURL.isEmpty ? "https://talkischeap.app" : downloadURL) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Simple semver comparison: "2.1.0" > "2.0.0"
    private func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}
