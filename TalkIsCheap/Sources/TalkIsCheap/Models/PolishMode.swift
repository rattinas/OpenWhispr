import Foundation

struct PolishMode: Identifiable, Codable, Hashable {
    let id: String
    var label: String
    var emoji: String
    var prompt: String?
    var isBuiltIn: Bool

    static let builtIn: [PolishMode] = [
        PolishMode(id: "raw", label: "Raw", emoji: "✏️",
                   prompt: nil, isBuiltIn: true),
        PolishMode(id: "clean", label: "Clean", emoji: "🧹",
                   prompt: "WICHTIG: Behalte die Sprache des Inputs bei. Gib NUR den Ergebnistext aus.\n\nKorrigiere nur Zeichensetzung und Gross-/Kleinschreibung. Entferne Füllwörter und Stotterer. Ändere sonst nichts.",
                   isBuiltIn: true),
        PolishMode(id: "professional", label: "Professional", emoji: "💼",
                   prompt: "WICHTIG: Behalte die Sprache des Inputs bei. Gib NUR den Ergebnistext aus.\n\nFormuliere als klare, professionelle Kommunikation. Korrigiere Grammatik, entferne Füllwörter. Präzise und direkt.",
                   isBuiltIn: true),
        PolishMode(id: "marketing", label: "Marketing", emoji: "📣",
                   prompt: "WICHTIG: Behalte die Sprache des Inputs bei. Gib NUR den Ergebnistext aus.\n\nFormuliere als überzeugende Marketing-Texte. Knackig, nutzenorientiert, ansprechend.",
                   isBuiltIn: true),
        PolishMode(id: "coding", label: "Code", emoji: "💻",
                   prompt: "WICHTIG: Behalte die Sprache des Inputs bei. Gib NUR den Ergebnistext aus.\n\nFormuliere als präzisen technischen Kommentar. Behalte alle technischen Begriffe exakt.",
                   isBuiltIn: true),
        PolishMode(id: "email", label: "Email", emoji: "📧",
                   prompt: "WICHTIG: Behalte die Sprache des Inputs bei. Gib NUR den Ergebnistext aus.\n\nFormuliere als gut strukturierte E-Mail. Professioneller Ton, klare Absätze.",
                   isBuiltIn: true),
        PolishMode(id: "casual", label: "Casual", emoji: "💬",
                   prompt: "WICHTIG: Behalte die Sprache des Inputs bei. Gib NUR den Ergebnistext aus.\n\nBereinige für eine Chat-Nachricht. Locker, kurz und natürlich.",
                   isBuiltIn: true),
    ]
}

/// Manages built-in + custom polish modes
final class PolishModeManager: ObservableObject {
    static let shared = PolishModeManager()

    @Published var customModes: [PolishMode] = []

    private let storageURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TalkIsCheap", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("custom_modes.json")
    }()

    var allModes: [PolishMode] { PolishMode.builtIn + customModes }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let modes = try? JSONDecoder().decode([PolishMode].self, from: data)
        else { return }
        customModes = modes
    }

    func save() {
        guard let data = try? JSONEncoder().encode(customModes) else { return }
        try? data.write(to: storageURL)
    }

    func add(label: String, emoji: String, prompt: String) {
        let id = label.lowercased().replacingOccurrences(of: " ", with: "_") + "_\(Int.random(in: 1000...9999))"
        customModes.append(PolishMode(id: id, label: label, emoji: emoji, prompt: prompt, isBuiltIn: false))
        save()
    }

    func remove(id: String) {
        customModes.removeAll { $0.id == id }
        save()
    }

    func updatePrompt(id: String, prompt: String) {
        if let idx = customModes.firstIndex(where: { $0.id == id }) {
            customModes[idx].prompt = prompt
            save()
        }
    }
}
