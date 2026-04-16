import SwiftUI

struct DictionaryView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Custom Dictionary") {
                Text("Add company names, technical terms, people's names, or other proper nouns that Whisper often transcribes wrong. One word or phrase per line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $settings.customDictionary)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .background(Color.secondary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Examples:")
                        .font(.caption.weight(.medium))
                    Text("Anthropic, Claude Sonnet 4.6\nBenedikt Rapp\nKubernetes, Docker Compose\nACME GmbH, Müller & Söhne KG")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 4)

                if !settings.customDictionary.isEmpty {
                    Text("\(wordCount) term\(wordCount == 1 ? "" : "s") in dictionary")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Section {
                HStack(spacing: 12) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("How it works").font(.caption.weight(.semibold))
                        Text("Your dictionary is sent to Whisper as a vocabulary hint AND to Claude during polishing to preserve exact spelling.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }
        }
        .formStyle(.grouped)
    }

    private var wordCount: Int {
        settings.customDictionary
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .count
    }
}
