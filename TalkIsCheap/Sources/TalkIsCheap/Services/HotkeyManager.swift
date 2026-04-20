import Cocoa
import Carbon

/// Global hotkey manager driven by user-configurable `TriggerPattern`s.
///
/// Each of the three modes (record / search / hands-free) has its own gesture
/// wired up in Settings → Hotkeys. This class listens to the raw modifier
/// event stream, matches events against every enabled pattern, and fires the
/// corresponding mode callback.
///
/// Architecture:
///   1. Source: CGEventTap (preferred) or NSEvent monitor (fallback without
///      accessibility permission). Both funnel into `ingestFlagsChanged(mask:)`.
///   2. Dispatcher: `ingestFlagsChanged` derives press/release edges per
///      modifier key, then updates a `PatternState` for each enabled pattern.
///   3. Callbacks: each pattern fires the mode's callbacks — record &
///      hands-free get `onKeyDown/onKeyUp`; search uses `onSearchKeyDown/Up`.
///
/// The matcher is gesture-type aware:
///   * `.hold(minMs)`       — start fires on press; only commits if the user
///                            actually held for `minMs` (short releases abort
///                            so a quick tap doesn't leak into the hold mode).
///                            Stop fires on release.
///   * `.taps(count)`       — inter-tap gap ≤ `learnedMaxInterTapMs` (the
///                            user's calibrated rhythm). `count`-th tap
///                            arming fires `onKeyDown` immediately; the very
///                            next press fires `onKeyUp`. Pure toggle.
///   * `.combo(modifiers:)` — primary key + all modifiers held simultaneously.
///                            `onKeyDown` on completion, `onKeyUp` when any
///                            of the required keys releases.
final class HotkeyManager {
    static let shared = HotkeyManager()

    // MARK: - Callbacks

    /// Record mode: hold-to-talk. onKeyDown → start recording,
    /// onKeyUp → stop & paste. onCancel → abort recording silently
    /// (e.g. when the "hold" was really a short tap).
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Fallback hands-free toggle callback — currently unused; hands-free
    /// mode now routes through onKeyDown/onKeyUp like record.
    var onHandsFreeToggle: (() -> Void)?

    /// Search mode. onSearchKeyDown → open search panel & start capturing
    /// audio; onSearchKeyUp → submit the query.
    var onSearchKeyDown: (() -> Void)?
    var onSearchKeyUp: (() -> Void)?

    // MARK: - Public state flags

    /// True while hands-free mode is actively recording. Used by MenuBarIcon.
    var isHandsFree: Bool { activeMode == .handsFree }

    /// When non-zero, all mode callbacks are suppressed and internal state is
    /// reset on each event. Use this during the calibration flow so the user
    /// can tap their pattern without accidentally starting recordings.
    /// Reference-counted so nested callers (e.g. two sheets) don't stomp each
    /// other.
    private var suspendDepth: Int = 0

    /// Suspend all hotkey callbacks. Balanced with `resumeCallbacks()`.
    func suspendCallbacks() {
        suspendDepth += 1
        // Drop any in-flight activation so resuming doesn't fire a stale stop.
        resetToggleState()
        Log.write("HotkeyManager: callbacks suspended (depth \(suspendDepth))")
    }

    func resumeCallbacks() {
        suspendDepth = max(0, suspendDepth - 1)
        resetToggleState()
        Log.write("HotkeyManager: callbacks resumed (depth \(suspendDepth))")
    }

    /// Reset toggle state (call when recording is cancelled externally so the
    /// next hotkey press starts a new recording rather than trying to stop one).
    func resetToggleState() {
        for mode in TriggerMode.allCases {
            states[mode]?.armed = false
            states[mode]?.activated = false
            states[mode]?.tapTimestamps.removeAll()
            states[mode]?.pendingCommit?.cancel()
            states[mode]?.pendingCommit = nil
        }
        activeMode = nil
    }

    // MARK: - Lifecycle

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadPatterns),
            name: .triggerPatternsChanged,
            object: nil
        )
        reloadPatternsSync()
    }

    func start() {
        stop()
        if AXIsProcessTrusted() {
            startWithCGEventTap()
            return
        }
        Log.write("HotkeyManager: using NSEvent monitor (CGEventTap unavailable)")
        startWithNSEventMonitor()
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil; runLoopSource = nil
    }

    // MARK: - Pattern storage

    /// Per-mode live pattern loaded from AppSettings.
    private var patterns: [TriggerMode: TriggerPattern] = [:]

    /// Per-mode match state (hold progress, recent-tap history, combo arming).
    private var states: [TriggerMode: PatternState] = [:]

    /// Which mode is currently "driving" — i.e. already fired onKeyDown and
    /// is waiting for its release/stop event. At most one mode at a time to
    /// keep state simple (prevents e.g. Record + HandsFree firing together).
    private var activeMode: TriggerMode?

    @objc private func reloadPatterns() { reloadPatternsSync() }

    private func reloadPatternsSync() {
        let s = AppSettings.shared
        patterns = [
            .record:    s.recordPattern,
            .search:    s.searchPattern,
            .handsFree: s.handsFreePattern,
        ]
        // Create fresh state slots for each mode.
        for mode in TriggerMode.allCases where states[mode] == nil {
            states[mode] = PatternState()
        }
    }

    // MARK: - Event monitors

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var lastMask: ModifierMask = []

    private func startWithNSEventMonitor() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in
            self?.ingestFlagsChanged(mask: maskFromNSEvent(e))
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            self?.ingestFlagsChanged(mask: maskFromNSEvent(e))
            return e
        }
        Log.write("HotkeyManager: NSEvent monitor active")
    }

    private func startWithCGEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = mgr.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passRetained(event)
                }
                if type == .flagsChanged {
                    mgr.ingestFlagsChanged(mask: maskFromCGEvent(event))
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.write("CGEventTap failed, falling back to NSEvent")
            startWithNSEventMonitor()
            return
        }
        self.eventTap = tap
        self.runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.write("HotkeyManager: CGEventTap active")
    }

    // MARK: - Dispatcher

    /// Core entry point — derives per-key press/release edges from a new
    /// `ModifierMask` snapshot and feeds each pattern's state machine.
    private func ingestFlagsChanged(mask: ModifierMask) {
        let previous = lastMask
        lastMask = mask

        // While suspended we still track the modifier state (so we don't
        // miss a release that arrives mid-suspension) but we don't feed
        // patterns. Resetting states on resume is handled by resetToggleState().
        if suspendDepth > 0 { return }

        let now = ProcessInfo.processInfo.systemUptime

        // Detect which modifier(s) changed state. Usually only one key flips
        // per event, but handle multiple defensively.
        for tk in TriggerKey.allCases {
            let wasDown = tk.isPressed(in: previous)
            let isDown  = tk.isPressed(in: mask)
            guard wasDown != isDown else { continue }
            handleEdge(key: tk, down: isDown, at: now, fullMask: mask)
        }
    }

    /// Unified dispatcher. Order of operations matters because multiple
    /// patterns may share a key (e.g. default Record=⌃hold + Search=⌃×2).
    ///
    ///   Press:
    ///     1. Stop-signal check: armed taps pattern → toggle it off.
    ///     2. Accumulate timestamps on every taps pattern that shares this key.
    ///        If the LONGEST count that has reached completion can still be
    ///        outgrown by an even longer pattern still inside its rhythm
    ///        window, DEFER the commit by the longer pattern's tolerance.
    ///        Otherwise commit immediately.
    ///     3. Holds + combos. Combos preempt in-flight holds (same as taps).
    ///
    ///   Release:
    ///     - Holds & combos finalise. Taps ignores releases.
    private func handleEdge(key: TriggerKey, down: Bool, at now: TimeInterval, fullMask: ModifierMask) {
        if down {
            // Step 1: armed-mode stop signal. Any mode whose `armed` flag is
            // set gets stopped when its primary key is pressed. This covers:
            //   - .taps modes that reached their count (armed by matchTaps)
            //   - HandsFree in any kind once activated (armed by release
            //     handlers — hands-free is inherently toggle-style).
            for mode in TriggerMode.allCases {
                guard let pattern = patterns[mode], pattern.enabled,
                      let state = states[mode] else { continue }
                guard state.armed, key == pattern.key else { continue }
                state.armed = false
                state.activated = false
                if activeMode == mode { activeMode = nil }
                fireOnKeyUp(for: mode)
                state.tapTimestamps.removeAll()
                return
            }

            // Step 2: accumulate timestamps + find the longest-ready pattern.
            var longestReady: (mode: TriggerMode, count: Int)?
            var longestPossibleCount: Int = 0
            var longestPossibleTolerance: TimeInterval = 0

            for mode in TriggerMode.allCases {
                guard let pattern = patterns[mode], pattern.enabled,
                      let state = states[mode] else { continue }
                guard case .taps(let count) = pattern.kind, key == pattern.key else { continue }
                // A new press invalidates any pending deferred commit — we
                // may need to defer again with fresh context.
                state.pendingCommit?.cancel()
                state.pendingCommit = nil

                let tolerance = Double(max(100, pattern.learnedMaxInterTapMs)) / 1000.0
                state.tapTimestamps = state.tapTimestamps.filter { now - $0 <= tolerance }
                state.tapTimestamps.append(now)

                // Track the longest count-pattern that exists on this key so
                // we know whether to defer the commit for disambiguation.
                if count > longestPossibleCount {
                    longestPossibleCount = count
                    longestPossibleTolerance = tolerance
                }
                if state.tapTimestamps.count >= count {
                    if longestReady == nil || count > longestReady!.count {
                        longestReady = (mode, count)
                    }
                }
            }

            if let winner = longestReady {
                let winnerMode = winner.mode
                if winner.count < longestPossibleCount {
                    // There's a longer pattern still growing — wait up to its
                    // tolerance window for one more tap before committing.
                    let task = DispatchWorkItem { [weak self] in
                        self?.commitTaps(mode: winnerMode)
                    }
                    states[winnerMode]?.pendingCommit = task
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + longestPossibleTolerance,
                        execute: task
                    )
                    // Don't run holds — the taps sequence is still in progress.
                    return
                }
                // No longer pattern possible — commit the winner now.
                commitTaps(mode: winnerMode)
                return
            }

            // Step 3: start holds and combos that aren't yet running. Modes
            // already in `armed` state (hands-free toggle) are skipped — the
            // user is inside an active hands-free session.
            for mode in TriggerMode.allCases {
                guard let pattern = patterns[mode], pattern.enabled,
                      let state = states[mode] else { continue }
                if state.armed { continue }
                switch pattern.kind {
                case .hold:
                    guard key == pattern.key, !state.activated else { continue }
                    if activeMode != nil && activeMode != mode { continue }
                    state.holdStartTime = now
                    state.activated = true
                    activeMode = mode
                    fireOnKeyDown(for: mode)
                case .combo(let modifiers):
                    let required: Set<TriggerKey> = Set([pattern.key] + modifiers)
                    guard required.contains(key) else { continue }
                    let allHeld = required.allSatisfy { $0.isPressed(in: fullMask) }
                    if allHeld && !state.activated {
                        // Combo completion wins over any in-flight hold (e.g.
                        // Ctrl-hold fired, then Opt arrived → Ctrl+Opt combo
                        // supersedes).
                        cancelProvisionalHolds(exceptMode: mode)
                        state.activated = true
                        activeMode = mode
                        fireOnKeyDown(for: mode)
                    }
                case .taps:
                    break
                }
            }
        } else {
            // Release — finalise holds, combos, and taps-with-release.
            //   stopMode==.release     → fire onKeyUp now, activeMode cleared.
            //   stopMode==.nextPress   → transition activated → armed, the next
            //                            primary-key press stops the mode.
            for mode in TriggerMode.allCases {
                guard let pattern = patterns[mode], pattern.enabled,
                      let state = states[mode] else { continue }
                switch pattern.kind {
                case .hold(let minMs):
                    guard key == pattern.key, state.activated else { continue }
                    let heldMs = Int(max(0, (now - state.holdStartTime) * 1000))
                    if heldMs < minMs {
                        // Short press — cancel regardless of stopMode.
                        state.activated = false
                        if activeMode == mode { activeMode = nil }
                        fireOnCancel(for: mode)
                    } else if pattern.stopMode == .nextPress {
                        // Long hold release → arm for next-press stop.
                        state.activated = false
                        state.armed = true
                    } else {
                        // Classic hold-to-talk: release ends the mode.
                        state.activated = false
                        if activeMode == mode { activeMode = nil }
                        fireOnKeyUp(for: mode)
                    }
                case .combo(let modifiers):
                    let required: Set<TriggerKey> = Set([pattern.key] + modifiers)
                    guard required.contains(key) else { continue }
                    let allHeld = required.allSatisfy { $0.isPressed(in: fullMask) }
                    if !allHeld && state.activated {
                        if pattern.stopMode == .nextPress {
                            state.activated = false
                            state.armed = true
                        } else {
                            state.activated = false
                            if activeMode == mode { activeMode = nil }
                            fireOnKeyUp(for: mode)
                        }
                    }
                case .taps:
                    // stopMode==.release uses hold-after-Nth-tap semantics —
                    // release of the primary key after activation ends the mode.
                    guard pattern.stopMode == .release,
                          key == pattern.key, state.activated else { continue }
                    state.activated = false
                    if activeMode == mode { activeMode = nil }
                    fireOnKeyUp(for: mode)
                }
            }
        }
    }

    /// Actually fire a taps pattern that's been picked as the winner. Called
    /// either inline (Step 2 commit) or deferred via `pendingCommit`.
    private func commitTaps(mode: TriggerMode) {
        guard let state = states[mode], let pattern = patterns[mode] else { return }
        state.pendingCommit = nil
        state.tapTimestamps.removeAll()
        // Clear any other pending commits on the same key (they lost the
        // disambiguation race).
        for other in TriggerMode.allCases where other != mode {
            states[other]?.pendingCommit?.cancel()
            states[other]?.pendingCommit = nil
            states[other]?.tapTimestamps.removeAll()
        }
        cancelProvisionalHolds(exceptMode: mode)
        activeMode = mode
        // stopMode drives whether we wait for the Nth key's release (hold
        // semantics — the user is about to hold the last tap while speaking)
        // or for the next primary-key press (toggle semantics).
        if pattern.stopMode == .release {
            state.activated = true
            state.armed = false
            // Track that this activation came from a taps gesture — release of
            // the primary key below will fire onKeyUp.
        } else {
            state.activated = false
            state.armed = true
        }
        fireOnKeyDown(for: mode)
    }

    /// Cancels any `.hold` pattern that fired provisionally on a press but
    /// was later superseded by a taps/combo activation. Only `.hold` kinds
    /// are considered "provisional" — armed taps and active combos are
    /// deliberate activations that don't get preempted.
    private func cancelProvisionalHolds(exceptMode: TriggerMode) {
        for mode in TriggerMode.allCases where mode != exceptMode {
            guard let pattern = patterns[mode],
                  let state = states[mode], state.activated else { continue }
            if case .hold = pattern.kind {
                state.activated = false
                if activeMode == mode { activeMode = nil }
                fireOnCancel(for: mode)
            }
        }
    }

    // MARK: - Callback dispatch

    private func fireOnKeyDown(for mode: TriggerMode) {
        Log.write("Hotkey \(mode.rawValue) ↓")
        switch mode {
        case .record, .handsFree:
            DispatchQueue.main.async { [weak self] in self?.onKeyDown?() }
        case .search:
            DispatchQueue.main.async { [weak self] in self?.onSearchKeyDown?() }
        }
    }

    private func fireOnKeyUp(for mode: TriggerMode) {
        Log.write("Hotkey \(mode.rawValue) ↑")
        switch mode {
        case .record, .handsFree:
            DispatchQueue.main.async { [weak self] in self?.onKeyUp?() }
        case .search:
            DispatchQueue.main.async { [weak self] in self?.onSearchKeyUp?() }
        }
    }

    private func fireOnCancel(for mode: TriggerMode) {
        Log.write("Hotkey \(mode.rawValue) cancel (short hold)")
        switch mode {
        case .record, .handsFree:
            DispatchQueue.main.async { [weak self] in self?.onCancel?() }
        case .search:
            // Search doesn't have a cancel path; the up-on-short-hold would
            // just paste an empty query — suppress by firing nothing.
            break
        }
    }
}

// MARK: - PatternState (per-mode scratch state)

/// Mutable scratch space for a single TriggerPattern's matcher. We keep this
/// as a class so we can mutate via let bindings inside the matcher.
private final class PatternState {
    var holdStartTime: TimeInterval = 0
    var tapTimestamps: [TimeInterval] = []
    /// True once the activation condition fired — waiting for the matching
    /// stop event (key release for hold/combo, next tap for taps).
    var activated: Bool = false
    /// For .taps only: true after the N-th tap arms the mode — the very next
    /// press will deactivate it.
    var armed: Bool = false
    /// Deferred-commit task set when a shorter taps pattern could have fired
    /// but might still be outgrown by a longer taps pattern on the same key.
    /// Cancelled on every subsequent press so we always commit the longest
    /// gesture the user actually performed.
    var pendingCommit: DispatchWorkItem?
}

// MARK: - Mask conversion helpers

/// Distil the modifier set from a CGEvent into our own OptionSet.
private func maskFromCGEvent(_ event: CGEvent) -> ModifierMask {
    var mask: ModifierMask = []
    if event.flags.contains(.maskControl)       { mask.insert(.control)  }
    if event.flags.contains(.maskAlternate)     { mask.insert(.option)   }
    if event.flags.contains(.maskShift)         { mask.insert(.shift)    }
    if event.flags.contains(.maskCommand)       { mask.insert(.command)  }
    if event.flags.contains(.maskSecondaryFn)   { mask.insert(.function) }
    return mask
}

/// Same for NSEvent — used in the accessibility-denied fallback.
private func maskFromNSEvent(_ event: NSEvent) -> ModifierMask {
    var mask: ModifierMask = []
    if event.modifierFlags.contains(.control)  { mask.insert(.control)  }
    if event.modifierFlags.contains(.option)   { mask.insert(.option)   }
    if event.modifierFlags.contains(.shift)    { mask.insert(.shift)    }
    if event.modifierFlags.contains(.command)  { mask.insert(.command)  }
    if event.modifierFlags.contains(.function) { mask.insert(.function) }
    return mask
}
