import SwiftUI

/// Settings → Hotkeys tab. One card per mode (record / search / hands-free),
/// each with enable toggle + key picker + kind picker + calibration entry.
struct HotkeySettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var calibratingMode: TriggerMode?
    @State private var conflictMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Wire each mode to whichever gesture feels natural. TalkIsCheap learns your personal tap rhythm so double-taps & triple-taps actually match the way you press.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // "How it works" card — lives here rather than in docs so users see
            // the exact gestures they have configured without leaving Settings.
            Section {
                howItWorksCard
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle")
                    Text("How it works")
                }
            }

            if let msg = conflictMessage {
                Section {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            ForEach(TriggerMode.allCases) { mode in
                Section {
                    modeCard(mode: mode)
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.sfSymbol)
                        Text(mode.title)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { detectConflicts() }
        .sheet(item: $calibratingMode) { mode in
            HotkeyCalibrationSheet(mode: mode) {
                detectConflicts()
            }
        }
    }

    // MARK: - "How it works" card

    /// Live tutorial that reads the user's actual patterns and describes the
    /// flow step by step for each mode. This is the primary place we teach
    /// customers the double-tap / combo / hands-free toggle semantics — the
    /// old app had no explanation of Command Mode anywhere in-product.
    @ViewBuilder
    private var howItWorksCard: some View {
        let rec = settings.recordPattern
        let srch = settings.searchPattern
        let hf = settings.handsFreePattern

        VStack(alignment: .leading, spacing: 14) {
            if rec.enabled {
                usageStep(
                    icon: "mic.fill",
                    title: "Record (dictate into anything)",
                    steps: recordSteps(for: rec),
                    footnote: "Short holds below the threshold are ignored so accidental taps don't leak audio."
                )
            }

            if srch.enabled {
                usageStep(
                    icon: "sparkle.magnifyingglass",
                    title: "Command Mode (voice search + connected tools)",
                    steps: searchSteps(for: srch),
                    footnote: "Connected services (Gmail, Calendar, Shopify) answer from live data. Crypto / stocks / weather work offline via public APIs."
                )
            }

            if hf.enabled {
                usageStep(
                    icon: "hands.sparkles.fill",
                    title: "Hands-Free (long dictation — walk & talk)",
                    steps: handsFreeSteps(for: hf),
                    footnote: hf.stopMode == .nextPress
                        ? "Toggle mode — activate once, come back when you're done. Keys can be released between activation and stop."
                        : "Hold-style — keys stay down while you dictate."
                )
            }

            // Personalised rhythm tip — only surfaced when the user hasn't
            // calibrated yet AND has at least one .taps pattern configured.
            let uncalibratedTaps = TriggerMode.allCases.contains { mode in
                let p = settings.pattern(for: mode)
                if case .taps = p.kind, p.calibrationSampleCount == 0, p.enabled {
                    return true
                }
                return false
            }
            if uncalibratedTaps {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your tap rhythm isn't calibrated yet")
                            .font(.caption.bold())
                        Text("Hit **Train my rhythm** on any tap-based mode below — TalkIsCheap will learn exactly how fast you double-tap and match you every time.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Usage step text builders (kept out of the ViewBuilder so Swift
    // doesn't try to treat local assignments as view expressions).

    private func recordSteps(for p: TriggerPattern) -> [String] {
        switch (p.kind, p.stopMode) {
        case (.hold, .release):
            return [
                "**Hold** \(p.kind.descriptionWith(primary: p.key)) and start speaking.",
                "**Release** — your text is polished by Claude Haiku and pasted at the cursor.",
            ]
        case (.hold, .nextPress):
            return [
                "Briefly press \(p.kind.descriptionWith(primary: p.key)) to start recording. Release.",
                "Speak for as long as you want.",
                "**Press \(p.key.glyph) \(p.key.label) once** to stop and paste.",
            ]
        case (.taps, .release):
            return [
                "Do \(p.kind.descriptionWith(primary: p.key)), **hold the final tap** and speak.",
                "**Release** — polished text lands at your cursor.",
            ]
        case (.taps, .nextPress):
            return [
                "Do \(p.kind.descriptionWith(primary: p.key)) to start recording.",
                "**Press \(p.key.glyph) \(p.key.label) once** to stop and paste.",
            ]
        case (.combo, .release):
            return [
                "**Hold** \(p.kind.descriptionWith(primary: p.key)) and speak.",
                "**Release** any of the keys — text lands at your cursor.",
            ]
        case (.combo, .nextPress):
            return [
                "Press \(p.kind.descriptionWith(primary: p.key)) briefly to start.",
                "**Press \(p.key.glyph) \(p.key.label) once** to stop and paste.",
            ]
        }
    }

    private func searchSteps(for p: TriggerPattern) -> [String] {
        let stopStep: String
        switch p.stopMode {
        case .release:
            stopStep = "**Keep \(p.key.glyph) \(p.key.label) held** while you speak. Release → answer."
        case .nextPress:
            stopStep = "**Press \(p.key.glyph) \(p.key.label) once** when you're done to submit. Answer streams in; follow-ups work inline."
        }
        return [
            "Do \(p.kind.descriptionWith(primary: p.key)). The search panel opens.",
            "**Speak your question.** (\"Wie viel Umsatz hatten wir gestern?\", \"freier Termin morgen?\", \"letzte Mail von Chris?\")",
            stopStep,
        ]
    }

    private func handsFreeSteps(for p: TriggerPattern) -> [String] {
        if p.stopMode == .release {
            return [
                "**Hold** \(p.kind.descriptionWith(primary: p.key)) and speak.",
                "**Release** when done — text lands at your cursor.",
            ]
        }
        return [
            "Do \(p.kind.descriptionWith(primary: p.key)) **briefly**.",
            "**Release** everything — recording keeps running. Speak for as long as you want, no keys held.",
            "**Press \(p.key.glyph) \(p.key.label) once** to stop and paste.",
        ]
    }

    @ViewBuilder
    private func usageStep(icon: String, title: String, steps: [String], footnote: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.caption.bold())
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(idx + 1).")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(try! AttributedString(markdown: step))
                            .font(.caption)
                    }
                }
            }
            .padding(.leading, 22)
            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.leading, 22)
        }
    }

    // MARK: - Card

    @ViewBuilder
    private func modeCard(mode: TriggerMode) -> some View {
        let binding = Binding<TriggerPattern>(
            get: { settings.pattern(for: mode) },
            set: { new in
                settings.setPattern(new, for: mode)
                detectConflicts()
            }
        )
        let pattern = binding.wrappedValue

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle(isOn: Binding(
                    get: { pattern.enabled },
                    set: { on in
                        var p = pattern
                        p.enabled = on
                        binding.wrappedValue = p
                    }
                )) {
                    Text(mode.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
            }

            if pattern.enabled {
                // Current gesture summary — the one-line description.
                HStack(spacing: 8) {
                    Text(pattern.kind.descriptionWith(primary: pattern.key))
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Spacer()
                    if pattern.calibrationSampleCount > 0, case .taps = pattern.kind {
                        Label("\(pattern.learnedMedianInterTapMs) ms median · ±\(pattern.learnedMaxInterTapMs) ms window",
                              systemImage: "waveform")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Key picker
                HStack {
                    Text("Key:").font(.caption.bold())
                    Picker("", selection: Binding(
                        get: { pattern.key },
                        set: { k in
                            var p = pattern; p.key = k
                            binding.wrappedValue = p
                        }
                    )) {
                        ForEach(TriggerKey.allCases) { tk in
                            Text("\(tk.glyph)  \(tk.label)").tag(tk)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    Spacer()
                }

                // Kind picker
                HStack {
                    Text("Gesture:").font(.caption.bold())
                    Picker("", selection: Binding(
                        get: { KindKind(pattern.kind) },
                        set: { kk in
                            var p = pattern
                            let newKind = kk.defaultValue(current: pattern.kind)
                            p.kind = newKind
                            // Re-pick the natural stopMode for this (mode, kind)
                            // pair so switching kind doesn't strand the user on
                            // a nonsensical default (e.g. Hold + nextPress).
                            p.stopMode = TriggerPattern.defaultStopMode(for: mode, kind: newKind)
                            binding.wrappedValue = p
                        }
                    )) {
                        Text("Hold").tag(KindKind.hold)
                        Text("Tap N×").tag(KindKind.taps)
                        Text("Combo").tag(KindKind.combo)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                    Spacer()
                }

                // Stop mode picker — "Release the key" (hold-style) vs
                // "Press again" (toggle). For .hold kinds both options make
                // sense (toggle = press once briefly, speak, press again to
                // stop). For .taps with .release = "double-tap-and-hold".
                HStack {
                    Text("Stop when you:").font(.caption.bold())
                    Picker("", selection: Binding(
                        get: { pattern.stopMode },
                        set: { sm in
                            var p = pattern
                            p.stopMode = sm
                            binding.wrappedValue = p
                        }
                    )) {
                        Text("Release").tag(StopMode.release)
                        Text("Press again").tag(StopMode.nextPress)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                    Spacer()
                }
                Text(pattern.stopMode.hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)

                // Kind-specific controls
                switch pattern.kind {
                case .hold(let ms):
                    HStack {
                        Text("Hold for:").font(.caption)
                        Slider(
                            value: Binding(
                                get: { Double(ms) },
                                set: { v in
                                    var p = pattern
                                    p.kind = .hold(minMs: Int(v.rounded()))
                                    binding.wrappedValue = p
                                }
                            ),
                            in: 50...600,
                            step: 10
                        )
                        .frame(maxWidth: 280)
                        Text("\(ms) ms")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                case .taps(let n):
                    HStack {
                        Text("Taps:").font(.caption)
                        Stepper(value: Binding(
                            get: { n },
                            set: { v in
                                var p = pattern
                                p.kind = .taps(count: max(2, min(6, v)))
                                binding.wrappedValue = p
                            }
                        ), in: 2...6) {
                            Text("\(n)× tap")
                                .font(.caption.monospacedDigit())
                        }
                        .frame(maxWidth: 140)
                        Spacer()
                        Button {
                            calibratingMode = mode
                        } label: {
                            Label("Train my rhythm", systemImage: "waveform.path.ecg")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                case .combo(let mods):
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Also hold:").font(.caption.bold())
                        HStack(spacing: 6) {
                            ForEach(TriggerKey.allCases.filter { $0 != pattern.key }) { k in
                                Toggle(isOn: Binding(
                                    get: { mods.contains(k) },
                                    set: { on in
                                        var new = mods
                                        if on && !new.contains(k) { new.append(k) }
                                        if !on { new.removeAll { $0 == k } }
                                        var p = pattern
                                        p.kind = .combo(modifiers: new)
                                        binding.wrappedValue = p
                                    }
                                )) {
                                    Text("\(k.glyph) \(k.label)").font(.caption)
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Conflict detection

    private func detectConflicts() {
        // Warn if two modes share the exact same gesture.
        var seen: [String: TriggerMode] = [:]
        var dupes: [(TriggerMode, TriggerMode)] = []
        for mode in TriggerMode.allCases {
            let p = settings.pattern(for: mode)
            guard p.enabled else { continue }
            let fingerprint = "\(p.key.rawValue)/\(p.kind.label)"
            if let existing = seen[fingerprint] {
                dupes.append((existing, mode))
            } else {
                seen[fingerprint] = mode
            }
        }
        if let first = dupes.first {
            conflictMessage = "\(first.0.title) and \(first.1.title) are both set to the same gesture — only one will fire. Pick different keys or tap counts."
        } else {
            conflictMessage = nil
        }
    }
}

// MARK: - Helper enum for kind picker

/// Flat enum over TriggerKind cases, used by the segmented picker. Keeps
/// selection tracking out of the TriggerKind itself (which carries payloads).
private enum KindKind: Hashable {
    case hold, taps, combo

    init(_ kind: TriggerKind) {
        switch kind {
        case .hold:  self = .hold
        case .taps:  self = .taps
        case .combo: self = .combo
        }
    }

    /// When user switches kind, fall back to the payload of the previous
    /// selection so sliders/steppers stay in sensible ranges.
    func defaultValue(current: TriggerKind) -> TriggerKind {
        switch self {
        case .hold:
            if case .hold(let ms) = current { return .hold(minMs: ms) }
            return .hold(minMs: 150)
        case .taps:
            if case .taps(let n) = current { return .taps(count: n) }
            return .taps(count: 2)
        case .combo:
            if case .combo(let mods) = current { return .combo(modifiers: mods) }
            return .combo(modifiers: [.shift])
        }
    }
}
