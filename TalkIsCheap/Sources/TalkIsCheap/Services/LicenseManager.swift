import Foundation
import CryptoKit

/// Offline license key validation
enum LicenseManager {
    private static let secret = "talkischeap-2026-lifetime-key".data(using: .utf8)!
    static let prefix = "TIC"

    static func validate(_ key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let parts = key.split(separator: "-").map(String.init)

        guard parts.count == 5, parts[0] == prefix else { return false }
        guard parts[1...4].allSatisfy({ $0.count == 5 && $0.allSatisfy({ $0.isLetter || $0.isNumber }) }) else { return false }

        let payload = parts[1...3].joined(separator: "-")
        let expectedSig = computeSignature(payload)
        return parts[4] == expectedSig
    }

    static func generate() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let groups = (0..<3).map { _ in
            String((0..<5).map { _ in chars.randomElement()! })
        }
        let payload = groups.joined(separator: "-")
        let sig = computeSignature(payload)
        return "\(prefix)-\(payload)-\(sig)"
    }

    static var isLicensed: Bool {
        validate(AppSettings.shared.licenseKey)
    }

    static var canUse: Bool {
        isLicensed || AppSettings.shared.remainingTrial > 0
    }

    private static func computeSignature(_ payload: String) -> String {
        let key = SymmetricKey(data: secret)
        let sig = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        let hex = sig.map { String(format: "%02X", $0) }.joined()
        return String(hex.prefix(5))
    }
}
