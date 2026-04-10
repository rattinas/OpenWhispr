#!/usr/bin/env swift
// TalkIsCheap License Key Generator
// Usage: swift generate_keys.swift [count]
// Output: one key per line, ready for CSV

import Foundation
import CryptoKit

let secret = "talkischeap-2026-lifetime-key".data(using: .utf8)!
let prefix = "TIC"
let count = CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 5) : 5

func computeSignature(_ payload: String) -> String {
    let key = SymmetricKey(data: secret)
    let sig = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
    return sig.map { String(format: "%02X", $0) }.joined().prefix(5).uppercased()
}

func generateKey() -> String {
    let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    let groups = (0..<3).map { _ in String((0..<5).map { _ in chars.randomElement()! }) }
    let payload = groups.joined(separator: "-")
    let sig = computeSignature(payload)
    return "\(prefix)-\(payload)-\(sig)"
}

func validateKey(_ key: String) -> Bool {
    let parts = key.split(separator: "-").map(String.init)
    guard parts.count == 5, parts[0] == prefix else { return false }
    let payload = parts[1...3].joined(separator: "-")
    return parts[4] == computeSignature(payload)
}

// Generate and output
for _ in 0..<count {
    let key = generateKey()
    assert(validateKey(key), "Generated invalid key: \(key)")
    print(key)
}

fputs("Generated \(count) valid license keys.\n", stderr)
