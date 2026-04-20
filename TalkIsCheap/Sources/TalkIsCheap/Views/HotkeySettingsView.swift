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
                    steps: [
                        "**Hold** \(rec.kind.descriptionWith(primary: rec.key)) and start speaking.",
                        "**Release** — your text is polished by Claude Haiku and pasted at the cursor.",
                    ],
                    footnote: "Short taps are ignored — only real holds trigger dictation.",
                )
            }

            if srch.enabled {
                usageStep(
                    icon: "sparkle.magnifyingglass",
                    title: "Command Mode (voice search + connected tools)",
                    steps: [
                        "Do \(srch.kind.descriptionWith(primary: srch.key)). The search panel opens.",
                        "**Speak your question.** (\"Wie viel Umsatz hatten wir gestern?\", \"freier Termin morgen?\", \"letzte Mail von Chris?\")",
                        "**Press \(srch.key.glyph) \(srch.key.label) once** to submit. Answer streams in; follow-ups work inline.",
                    ],
                    footnote: "Connected services (Gmail, Calendar, Shopify) answer from live data. Crypto / stocks / weather work offline via public APIs.",
                )
            }

            if hf.enabled {
                usageStep(
                    icon: "hands.sparkles.fill",
                    title: "Hands-Free (long dictation — walk & talk)",
                    steps: [
                        "Do \(hf.kind.descriptionWith(primary: hf.key)) **briefly**.",
                        "**Release** everything — recording keeps running. Speak for as long as you want, no keys held.",
                        "**Press \(hf.key.glyph) \(hf.key.label) once** to stop and paste.",
                    ],
                    footnote: "Unlike Record, Hands-Free is a toggle — activate once, come back when you're done."
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
                            p.kind = kk.defaultValue(current: pattern.kind)
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
