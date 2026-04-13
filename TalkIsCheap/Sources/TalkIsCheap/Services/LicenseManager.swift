import Foundation
import CryptoKit
import IOKit

/// Hardware-bound license activation
enum LicenseManager {
    private static let secret = "talkischeap-2026-lifetime-key".data(using: .utf8)!
    static let prefix = "TIC"
    private static let baseURL = "https://talkischeap.app/api"

    // MARK: - Hardware UUID

    static func hardwareUUID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }

        guard service != 0,
              let uuidRef = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0),
              let uuid = uuidRef.takeRetainedValue() as? String
        else {
            return "unknown-\(ProcessInfo.processInfo.hostName)"
        }
        return uuid
    }

    // MARK: - Format Validation (offline pre-check)

    static func validateFormat(_ key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let parts = key.split(separator: "-").map(String.init)

        guard parts.count == 5, parts[0] == prefix else { return false }
        guard parts[1...4].allSatisfy({ $0.count == 5 && $0.allSatisfy({ $0.isLetter || $0.isNumber }) }) else { return false }

        let payload = parts[1...3].joined(separator: "-")
        let expectedSig = computeSignature(payload)
        return parts[4] == expectedSig
    }

    // MARK: - Online Activation

    enum ActivationResult {
        case success(token: String)
        case alreadyActivated(token: String)
        case invalidKey
        case maxReached(String)
        case revoked
        case networkError(String)
    }

    static func activate(key: String) async -> ActivationResult {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        guard validateFormat(key) else { return .invalidKey }

        let hwid = hardwareUUID()
        let machineName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

        let body: [String: String] = [
            "licenseKey": key,
            "hardwareId": hwid,
            "machineName": machineName,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            return .networkError("Failed to encode request")
        }

        var request = URLRequest(url: URL(string: "\(baseURL)/activate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .networkError("Invalid response")
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

            switch httpResponse.statusCode {
            case 200:
                let token = json["activationToken"] as? String ?? ""
                let status = json["status"] as? String ?? ""
                if status == "activated" {
                    // Save activation locally
                    let settings = AppSettings.shared
                    settings.licenseKey = key
                    settings.activationToken = token
                    settings.activatedAt = json["activatedAt"] as? String ?? ""
                    return .success(token: token)
                }
                return .alreadyActivated(token: token)

            case 403:
                let error = json["error"] as? String ?? ""
                if error.contains("revoked") { return .revoked }
                return .maxReached(error)

            case 404:
                return .invalidKey

            default:
                return .networkError(json["error"] as? String ?? "Server error (\(httpResponse.statusCode))")
            }
        } catch {
            return .networkError(error.localizedDescription)
        }
    }

    // MARK: - Deactivation

    static func deactivate() async -> Bool {
        let settings = AppSettings.shared
        let key = settings.licenseKey
        let hwid = hardwareUUID()

        guard !key.isEmpty else { return false }

        let body: [String: String] = ["licenseKey": key, "hardwareId": hwid]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return false }

        var request = URLRequest(url: URL(string: "\(baseURL)/deactivate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return false
            }

            // Clear local activation
            await MainActor.run {
                settings.licenseKey = ""
                settings.activationToken = ""
                settings.activatedAt = ""
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Periodic Validation

    static func validateOnline() async -> Bool? {
        let settings = AppSettings.shared
        let key = settings.licenseKey
        let hwid = hardwareUUID()

        guard !key.isEmpty, !settings.activationToken.isEmpty else { return false }

        let body: [String: String] = ["licenseKey": key, "hardwareId": hwid]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: URL(string: "\(baseURL)/validate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil // Network error — don't invalidate
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            return json["valid"] as? Bool ?? false
        } catch {
            return nil // Network unreachable — grace period
        }
    }

    // MARK: - State

    static var isLicensed: Bool {
        !AppSettings.shared.activationToken.isEmpty
    }

    static var canUse: Bool {
        isLicensed || AppSettings.shared.remainingTrial > 0
    }

    // MARK: - Key Generation (dev only)

    static func generate() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let groups = (0..<3).map { _ in
            String((0..<5).map { _ in chars.randomElement()! })
        }
        let payload = groups.joined(separator: "-")
        let sig = computeSignature(payload)
        return "\(prefix)-\(payload)-\(sig)"
    }

    private static func computeSignature(_ payload: String) -> String {
        let key = SymmetricKey(data: secret)
        let sig = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        let hex = sig.map { String(format: "%02X", $0) }.joined()
        return String(hex.prefix(5))
    }
}
