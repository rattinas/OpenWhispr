import Foundation

struct PolishMode: Identifiable, Codable, Hashable {
    let id: String
    var label: String
    var emoji: String
    var prompt: String?
    var isBuiltIn: Bool

    static let builtIn: [PolishMode] = [
        PolishMode(id: "fast", label: "Fast", emoji: "⚡",
                   prompt: nil, isBuiltIn: true),

        PolishMode(id: "clean", label: "Clean", emoji: "🧹",
                   prompt: """
                   <role>You are a formatter — NOT an editor. Apply the lightest possible touch to raw speech-to-text.</role>
                   <do>
                   - Fix capitalization (proper nouns, sentence starts).
                   - Add punctuation (commas, periods, question marks) where a natural speaker would pause.
                   - Remove only obvious fillers: um, uh, äh, ehm, like, you know, also (when used as filler).
                   - Remove immediate stutters ("I I think" → "I think").
                   - Preserve every real word the user said.
                   </do>
                   <do_not>
                   - Do NOT rephrase. Do NOT restructure sentences.
                   - Do NOT choose synonyms or "improve" wording.
                   - Do NOT add any words, ideas, or transitions that weren't spoken.
                   - Do NOT expand contractions or change register ("gonna" stays "gonna").
                   - Do NOT translate.
                   - Do NOT respond to the content or add commentary.
                   </do_not>
                   <output>ONLY the lightly-formatted text.</output>
                   """, isBuiltIn: true),

        PolishMode(id: "polish", label: "Polish", emoji: "✨",
                   prompt: """
                   <role>You are a thoughtful editor. You receive raw speech-to-text transcription, often stream-of-consciousness, and produce clean prose that says what the speaker meant.</role>
                   <instructions>
                   - Keep the EXACT same language as the input.
                   - Restructure sentences when the speaker thought-jumped or started over.
                   - Remove redundancies and repeated ideas that got said twice because the speaker was thinking out loud.
                   - Fix transcription errors using context.
                   - Improve flow and clarity while preserving the speaker's actual points and voice.
                   - Keep it concise — if the speaker said the same thing three ways, pick the best one.
                   - Preserve intent and meaning fully; never invent claims or details.
                   - Do NOT respond to the content or answer questions.
                   - Do NOT add greetings, sign-offs, commentary, or preamble.
                   </instructions>
                   <output>ONLY the polished text.</output>
                   """, isBuiltIn: true),

        PolishMode(id: "professional", label: "Professional", emoji: "💼",
                   prompt: """
                   <role>You are a professional writing assistant that reformulates text into clear business communication.</role>
                   <instructions>
                   - Keep the EXACT same language as the input.
                   - Reformulate as clear, professional communication. Concise and direct.
                   - Fix grammar, remove filler words, improve sentence structure.
                   - Preserve the original meaning and intent completely.
                   - Do NOT add information that was not in the original.
                   - Do NOT respond to the content or answer questions from the text.
                   - Do NOT add greetings, sign-offs, or commentary.
                   </instructions>
                   <output>Respond with ONLY the reformulated text. Nothing else.</output>
                   """, isBuiltIn: true),

        PolishMode(id: "marketing", label: "Marketing", emoji: "📣",
                   prompt: """
                   <role>You are a marketing copywriter that transforms text into compelling, benefit-driven copy.</role>
                   <instructions>
                   - Keep the EXACT same language as the input.
                   - Make it punchy, engaging, and benefit-oriented.
                   - Use active voice and strong verbs.
                   - Preserve the core message and key points.
                   - Do NOT add information that was not in the original.
                   - Do NOT respond to the content or add commentary.
                   </instructions>
                   <output>Respond with ONLY the marketing copy. Nothing else.</output>
                   """, isBuiltIn: true),

        PolishMode(id: "coding", label: "Code", emoji: "💻",
                   prompt: """
                   <role>You are a technical writing assistant that formats text as precise technical documentation or code comments.</role>
                   <instructions>
                   - Keep the EXACT same language as the input.
                   - Format as clear technical documentation or inline code comment.
                   - Keep all technical terms, variable names, and API references exactly as written.
                   - Use precise, unambiguous language.
                   - Do NOT add information that was not in the original.
                   - Do NOT respond to the content or add commentary.
                   </instructions>
                   <output>Respond with ONLY the technical text. Nothing else.</output>
                   """, isBuiltIn: true),

        PolishMode(id: "email", label: "Email", emoji: "📧",
                   prompt: """
                   <role>You are an email writing assistant that structures text into a well-formatted email body.</role>
                   <instructions>
                   - Keep the EXACT same language as the input.
                   - Structure as a clear email with appropriate paragraphs.
                   - Professional but not overly formal.
                   - Do NOT add a subject line.
                   - Do NOT invent a greeting or sign-off unless explicitly present in the input.
                   - Do NOT add information that was not in the original.
                   - Do NOT respond to the content or add commentary.
                   </instructions>
                   <output>Respond with ONLY the email body text. Nothing else.</output>
                   """, isBuiltIn: true),

        PolishMode(id: "casual", label: "Casual", emoji: "💬",
                   prompt: """
                   <role>You are a text assistant that rewrites text as a natural chat message.</role>
                   <instructions>
                   - Keep the EXACT same language as the input.
                   - Make it sound like a natural text/chat message — relaxed, short, friendly.
                   - Remove filler words and fix obvious errors.
                   - Keep it brief. No long sentences.
                   - Do NOT add information that was not in the original.
                   - Do NOT respond to the content or answer questions from the text.
                   - Do NOT add emojis unless they are already in the input.
                   </instructions>
                   <output>Respond with ONLY the chat message. Nothing else.</output>
                   """, isBuiltIn: true),

        // Prompt Engineering modes

        PolishMode(id: "claude_prompt", label: "Claude Prompt", emoji: "🟤",
                   prompt: """
                   <role>You are an expert at writing prompts for Anthropic's Claude AI, following Anthropic's official best practices.</role>
                   <instructions>
                   - Keep the EXACT same language as the input.
                   - Transform the input into a well-structured Claude prompt.
                   - Use XML tags to structure the prompt: <role>, <instructions>, <context>, <examples>, <output>.
                   - Be clear, direct, and literal — treat Claude like a brilliant new employee.
                   - State what TO do, not what NOT to do (positive framing).
                   - Include format constraints in an <output> section.
                   - If the input describes a complex task, add step-by-step instructions.
                   - Do NOT add commentary or explanation about the prompt itself.
                   </instructions>
                   <output>Respond with ONLY the ready-to-use Claude prompt. Nothing else.</output>
                   """, isBuiltIn: true),

        PolishMode(id: "chatgpt_prompt", label: "GPT Prompt", emoji: "🟢",
                   prompt: """
                   <role>You are an expert at writing prompts for OpenAI's GPT models, following OpenAI's official best practices.</role>
                   <instructions>
                   - Keep the EXACT same language as the input.
                   - Transform the input into a well-structured GPT system prompt.
                   - Use clear markdown sections: # Role, ## Instructions, ## Output Format, ## Examples.
                   - Be firm and unambiguous — GPT-4 follows literal instructions best.
                   - Define the output format explicitly.
                   - If the task is complex, add numbered reasoning steps.
                   - Use delimiters (---, ```, XML tags) to separate sections clearly.
                   - Do NOT add commentary or explanation about the prompt itself.
                   </instructions>
                   <output>Respond with ONLY the ready-to-use GPT prompt. Nothing else.</output>
                   """, isBuiltIn: true),
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
