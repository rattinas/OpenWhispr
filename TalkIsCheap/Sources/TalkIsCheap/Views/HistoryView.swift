import SwiftUI

struct HistoryView: View {
    @ObservedObject var history = TranscriptionHistory.shared

    var body: some View {
        VStack(spacing: 0) {
            // Stats bar
            HStack {
                Label("\(history.todayWordCount) words today", systemImage: "calendar")
                Spacer()
                Label("\(history.totalWordCount) total", systemImage: "sum")
                Spacer()
                Label("\(history.totalCount) transcriptions", systemImage: "number")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding()
            .background(Color.secondary.opacity(0.05))

            Divider()

            if history.entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("No transcriptions yet")
                        .foregroundStyle(.secondary)
                    Text("Hold your hotkey and speak to get started")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(history.entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(entry.polishedText)
                                    .font(.body)
                                    .lineLimit(3)
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.polishedText, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .help("Copy to clipboard")
                            }

                            HStack(spacing: 8) {
                                Text(entry.timestamp, style: .relative)
                                Text("·")
                                Text("\(entry.wordCount)w")
                                Text("·")
                                Text(String(format: "%.1fs", entry.duration))
                                Text("·")
                                Text(entry.mode)
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Clear History") {
                    history.clear()
                }
                .foregroundStyle(.red)
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(history.entries.isEmpty)
            }
            .padding(8)
        }
        .frame(width: 500, height: 400)
    }
}
