import SwiftUI
import AppKit

/// Custom menu bar icon — cassette that changes state
struct MenuBarIcon: View {
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            switch state.status {
            case .recording:
                // Red dot when recording
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
            case .transcribing, .polishing, .loading:
                Image(systemName: "ellipsis.circle")
            default:
                // Cassette template image
                if let img = loadTemplateImage() {
                    Image(nsImage: img)
                } else {
                    Image(systemName: "mic")
                }
            }
        }
    }

    private func loadTemplateImage() -> NSImage? {
        // Try to load from app bundle Resources
        let paths = [
            Bundle.main.path(forResource: "cassetteTemplate", ofType: "png"),
            Bundle.main.resourcePath.map { $0 + "/Resources/cassetteTemplate.png" },
        ].compactMap { $0 }

        for path in paths {
            if let img = NSImage(contentsOfFile: path) {
                img.isTemplate = true
                img.size = NSSize(width: 18, height: 18)
                return img
            }
        }

        // Fallback: try absolute path (development)
        let devPath = "/Users/bene/Documents/Projekte/OpenWhispr/TalkIsCheap/Resources/cassetteTemplate.png"
        if let img = NSImage(contentsOfFile: devPath) {
            img.isTemplate = true
            img.size = NSSize(width: 18, height: 18)
            return img
        }

        return nil
    }
}
