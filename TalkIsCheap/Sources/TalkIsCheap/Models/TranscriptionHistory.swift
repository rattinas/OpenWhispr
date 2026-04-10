import Foundation

struct TranscriptionEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let rawText: String
    let polishedText: String
    let mode: String
    let duration: Double
    let wordCount: Int
}

/// Simple file-based transcription history
@MainActor
final class TranscriptionHistory: ObservableObject {
    static let shared = TranscriptionHistory()

    @Published var entries: [TranscriptionEntry] = []

    private let storageURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TalkIsCheap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init() { load() }

    func add(raw: String, polished: String, mode: String, duration: Double) {
        let entry = TranscriptionEntry(
            id: UUID(),
            timestamp: Date(),
            rawText: raw,
            polishedText: polished,
            mode: mode,
            duration: duration,
            wordCount: polished.split(separator: " ").count
        )
        entries.insert(entry, at: 0)
        if entries.count > 500 { entries = Array(entries.prefix(500)) }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    var todayWordCount: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return entries.filter { $0.timestamp >= start }.reduce(0) { $0 + $1.wordCount }
    }

    var totalWordCount: Int {
        entries.reduce(0) { $0 + $1.wordCount }
    }

    var totalCount: Int { entries.count }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([TranscriptionEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: storageURL)
    }
}
