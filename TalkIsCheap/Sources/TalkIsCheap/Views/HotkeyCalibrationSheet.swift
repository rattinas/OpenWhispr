import SwiftUI
import AppKit

/// Guided "train my rhythm" flow for a `.taps` pattern. Captures the user
/// tapping their configured gesture `sampleGoal` times in a row, collects the
/// inter-tap gaps per rep, and derives a personalised `learnedMaxInterTapMs`
/// tolerance = `median × 1.5` (with outlier clipping).
///
/// The sheet listens for raw modifier `flagsChanged` events while visible via
/// an NSEvent global+local monitor. HotkeyManager itself keeps running, which
/// is fine — the user's taps during calibration will harmlessly match their
/// current pattern, but the sheet pauses the mode's callback by bumping
/// activation state. (For record/hands-free that'd normally start a recording;
/// we short-circuit by flagging calibration mode.)
struct HotkeyCalibrationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mode: TriggerMode
    var onSaved: () -> Void = {}

    @State private var pattern: TriggerPattern
    @State private var currentRepTaps: [TimeInterval] = []
    @State private var completedReps: [[Double]] = []   // per-rep inter-tap gaps, ms
    @State private var monitors: [Any] = []
    @State private var resetTask: Task<Void, Never>?
    @State private var lastMessage: String = "Ready when you are"

    private let sampleGoal = 5

    init(mode: TriggerMode, onSaved: @escaping () -> Void = {}) {
        self.mode = mode
        self._pattern = State(initialValue: AppSettings.shared.pattern(for: mode))
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // ScrollView is a safety net — if the Mac has a tiny screen or a
            // larger font size the results box still reaches the user.
            ScrollView { content }
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .onAppear {
            // Mute the live HotkeyManager so Ctrl-taps during calibration
            // don't accidentally start a recording or open Command Mode.
            HotkeyManager.shared.suspendCallbacks()
            startMonitoring()
        }
        .onDisappear {
            stopMonitoring()
            resetTask?.cancel()
            HotkeyManager.shared.resumeCallbacks()
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("Train your rhythm")
                    .font(.headline)
                Text("Tap your pattern \(sampleGoal)× — we'll match your speed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var content: some View {
        VStack(spacing: 18) {
            // Big prompt with the configured gesture
            VStack(spacing: 6) {
                Text(gesturePrompt)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("as fast (or slow) as you'd really do it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 12)

            // Current rep indicator dots
            if case .taps(let count) = pattern.kind {
                HStack(spacing: 8) {
                    ForEach(0..<count, id: \.self) { i in
                        Circle()
                            .fill(i < currentRepTaps.count ? Color.orange : Color.secondary.opacity(0.2))
                            .frame(width: 14, height: 14)
                    }
                }
            }

            // Sample counter
            HStack(spacing: 10) {
                ProgressView(value: Double(completedReps.count), total: Double(sampleGoal))
                    .tint(.orange)
                    .frame(maxWidth: 220)
                Text("\(completedReps.count) / \(sampleGoal)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Status line
            Text(lastMessage)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(minHeight: 16)

            if completedReps.count >= sampleGoal {
                resultsBox
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    private var resultsBox: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Calibration complete")
                    .font(.caption.bold())
                Spacer()
            }
            HStack {
                Text("Median gap:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(computedMedian) ms")
                    .font(.caption.bold().monospacedDigit())
            }
            HStack {
                Text("Tolerance (saved):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(computedTolerance) ms")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 320)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if completedReps.count >= sampleGoal {
                Button {
                    completedReps.removeAll()
                    currentRepTaps.removeAll()
                    lastMessage = "Restarted"
                } label: {
                    Label("Retrain", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)

                Button {
                    savePattern()
                    onSaved()
                    dismiss()
                } label: {
                    Text("Save").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    // MARK: - Computed helpers

    private var gesturePrompt: String {
        let keyGlyph = pattern.key.glyph + " " + pattern.key.label
        switch pattern.kind {
        case .taps(let n):   return "\(n)× \(keyGlyph)"
        case .hold(let ms):  return "Hold \(keyGlyph) \(ms) ms"
        case .combo(let m):  return (pattern.key.glyph + m.map(\.glyph).joined())
        }
    }

    private var allGaps: [Double] {
        completedReps.flatMap { $0 }
    }

    private var computedMedian: Int {
        let gaps = allGaps.sorted()
        if gaps.isEmpty { return 0 }
        let mid = gaps.count / 2
        let median = gaps.count % 2 == 0 ? (gaps[mid - 1] + gaps[mid]) / 2 : gaps[mid]
        return Int(median.rounded())
    }

    /// Tolerance = median × 1.5, clamped to [150, 800] ms.
    private var computedTolerance: Int {
        let t = Int((Double(computedMedian) * 1.5).rounded())
        return min(800, max(150, t))
    }

    // MARK: - Capture

    private func startMonitoring() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged]
        let g = NSEvent.addGlobalMonitorForEvents(matching: mask) { e in
            handleEvent(e)
        }
        let l = NSEvent.addLocalMonitorForEvents(matching: mask) { e in
            handleEvent(e)
            return e
        }
        if let g { monitors.append(g) }
        if let l { monitors.append(l) }
    }

    private func stopMonitoring() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }

    /// State for detecting press edges per key across event deltas.
    @State private var previouslyDown: Bool = false

    private func handleEvent(_ event: NSEvent) {
        // Only care about this pattern's primary key pressing DOWN.
        let isDown = {
            switch pattern.key {
            case .control:  return event.modifierFlags.contains(.control)
            case .option:   return event.modifierFlags.contains(.option)
            case .shift:    return event.modifierFlags.contains(.shift)
            case .command:  return event.modifierFlags.contains(.command)
            case .function: return event.modifierFlags.contains(.function)
            }
        }()
        let wasDown = previouslyDown
        previouslyDown = isDown

        // Only count the press edge.
        guard isDown && !wasDown else { return }
        guard completedReps.count < sampleGoal else { return }

        let now = ProcessInfo.processInfo.systemUptime
        currentRepTaps.append(now)

        if case .taps(let count) = pattern.kind {
            // If the gap since the previous tap is huge (>1.5s), discard the
            // first and treat this as a new rep's start.
            if currentRepTaps.count > 1 {
                let gap = (currentRepTaps.last! - currentRepTaps[currentRepTaps.count - 2]) * 1000
                if gap > 1500 {
                    currentRepTaps = [now]
                    lastMessage = "Too slow — starting over"
                    scheduleReset()
                    return
                }
            }
            if currentRepTaps.count >= count {
                // Completed a rep — record inter-tap gaps.
                let gaps = zip(currentRepTaps.dropFirst(), currentRepTaps).map { ($0 - $1) * 1000 }
                completedReps.append(Array(gaps))
                currentRepTaps.removeAll()
                lastMessage = "Nice — \(completedReps.count)/\(sampleGoal) captured"
                if completedReps.count >= sampleGoal {
                    lastMessage = "All set. Review & save."
                }
            }
            scheduleReset()
        } else {
            // Non-taps kinds shouldn't show up in calibration — early out.
            dismiss()
        }
    }

    /// Auto-reset the in-progress rep if the user waits too long between
    /// taps. Runs after each tap; superseded by the next tap's call.
    private func scheduleReset() {
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if !Task.isCancelled && !currentRepTaps.isEmpty && completedReps.count < sampleGoal {
                currentRepTaps.removeAll()
                lastMessage = "Timed out — tap again"
            }
        }
    }

    // MARK: - Save

    private func savePattern() {
        var updated = pattern
        updated.learnedMaxInterTapMs = computedTolerance
        updated.learnedMedianInterTapMs = computedMedian
        updated.calibrationSampleCount = completedReps.count
        AppSettings.shared.setPattern(updated, for: mode)
    }
}
