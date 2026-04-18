import SwiftUI

/// Animated cassette tape — spools rotate when recording
struct CassetteView: View {
    let isActive: Bool
    @State private var rotation: Double = 0

    // Transparent glass style
    let cassetteGlass = Color.white.opacity(0.15)
    let cassetteStroke = Color.white.opacity(0.3)
    let coral = Color(red: 0.95, green: 0.35, blue: 0.25)
    let cream = Color.white.opacity(0.7)
    let dark = Color.white.opacity(0.08)

    var body: some View {
        ZStack {
            // Cassette body — glass/transparent
            RoundedRectangle(cornerRadius: 4)
                .fill(cassetteGlass)
                .frame(width: 52, height: 32)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(cassetteStroke, lineWidth: 0.5)
                )

            // Label area (top)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.2))
                .frame(width: 40, height: 10)
                .offset(y: -7)

            // "REC" text
            Text("REC")
                .font(.system(size: 5, weight: .black, design: .rounded))
                .foregroundStyle(isActive ? coral : Color.white.opacity(0.4))
                .offset(y: -7)

            // Tape window
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(0.3))
                .frame(width: 30, height: 9)
                .offset(y: 5)

            // Left spool
            spoolView
                .offset(x: -8, y: 5)

            // Right spool
            spoolView
                .offset(x: 8, y: 5)

            // Tape between spools
            if isActive {
                TapeWaveView()
                    .frame(width: 6, height: 3)
                    .offset(y: 5)
            }

            // Recording indicator dot
            if isActive {
                Circle()
                    .fill(coral)
                    .frame(width: 3, height: 3)
                    .offset(x: 19, y: -8)
                    .opacity(rotation.truncatingRemainder(dividingBy: 2) < 1 ? 1 : 0.3)
            }
        }
        .onAppear {
            if isActive { startSpinning() }
        }
        .onChange(of: isActive) { _, active in
            if active { startSpinning() }
        }
    }

    private var spoolView: some View {
        ZStack {
            // Spool outer
            Circle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 7, height: 7)
                .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 0.5))

            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 4, height: 4)

                ForEach(0..<3, id: \.self) { i in
                    Rectangle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 0.5, height: 3)
                        .rotationEffect(.degrees(Double(i) * 120 + rotation))
                }
            }
        }
    }

    private func startSpinning() {
        guard isActive else { return }
        withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
            rotation = 360
        }
    }
}

/// Animated tape wave between spools
struct TapeWaveView: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        WaveShape(phase: phase)
            .stroke(Color(red: 0.95, green: 0.92, blue: 0.87).opacity(0.6), lineWidth: 1)
            .onAppear {
                withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: false)) {
                    phase = .pi * 2
                }
            }
    }
}

struct WaveShape: Shape {
    var phase: CGFloat
    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        let amplitude = rect.height / 2
        path.move(to: CGPoint(x: 0, y: midY))
        for x in stride(from: 0, through: rect.width, by: 1) {
            let y = midY + sin((x / rect.width) * .pi * 3 + phase) * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
        }
        return path
    }
}

/// Floating panel window at bottom center of screen
final class EqualizerPanel: NSPanel {
    // Wider than the cassette so we can show live-preview text above it
    static let panelWidth: CGFloat = 440
    static let panelHeight: CGFloat = 120

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
    }

    func positionAtBottom() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.minY + 20
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Manages the floating cassette overlay
@MainActor
final class EqualizerOverlay: ObservableObject {
    static let shared = EqualizerOverlay()

    @Published var isVisible = false
    @AppStorage("equalizerEnabled") var isEnabled = true

    private var panel: EqualizerPanel?

    func show() {
        guard isEnabled else { return }

        if panel == nil {
            let p = EqualizerPanel()
            let hostView = NSHostingView(rootView: CassetteOverlayContent())
            p.contentView = hostView
            self.panel = p
        }

        panel?.positionAtBottom()
        panel?.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }
}

/// The SwiftUI content inside the floating panel
private struct CassetteOverlayContent: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var live = LiveTranscriptionService.shared

    var body: some View {
        VStack(spacing: 6) {
            // Live-preview bubble — shows on-device SFSpeechRecognizer text
            // while the cloud pipeline runs in parallel. Collapses when empty
            // so the overlay is just the cassette.
            if state.status == .recording, !live.liveText.isEmpty {
                Text(live.liveText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black.opacity(0.72))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
                    .frame(maxWidth: 420)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if case .transcribing = state.status {
                statusBubble("Transcribing…")
            } else if case .polishing = state.status {
                statusBubble("Polishing…")
            }

            CassetteView(isActive: state.status == .recording)
                .scaleEffect(settings.cassetteScale)
                .opacity(settings.cassetteOpacity)
                .shadow(color: .black.opacity(0.3 * settings.cassetteOpacity), radius: 6, y: 3)
        }
        .animation(.easeOut(duration: 0.15), value: live.liveText)
        .animation(.easeOut(duration: 0.15), value: state.status)
        .frame(width: EqualizerPanel.panelWidth, height: EqualizerPanel.panelHeight, alignment: .bottom)
    }

    private func statusBubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.55))
            )
    }
}
