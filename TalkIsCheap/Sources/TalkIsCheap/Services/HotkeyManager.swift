import Cocoa

/// Global hotkey manager with Push-to-Talk AND Hands-Free modes.
/// - Push-to-talk: Hold CTRL to record, release to stop
/// - Hands-free: Double-tap CTRL to start, single tap CTRL to stop
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onHandsFreeToggle: (() -> Void)?

    // Search hotkey (Ctrl+Cmd)
    var onSearchKeyDown: (() -> Void)?
    var onSearchKeyUp: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var controlIsDown = false
    private var otherKeyPressed = false
    private var cmdIsDown = false

    // Hands-free state
    private var handsFreeActive = false
    private var lastCtrlReleaseTime: TimeInterval = 0
    private var pushStartTime: TimeInterval = 0
    private let doubleTapWindow: TimeInterval = 0.4
    private let maxTapDuration: TimeInterval = 0.25  // short tap = potential double-tap

    private var targetKeyCode: Int { AppSettings.shared.hotkeyCode }
    private var isModifierHotkey: Bool { targetKeyCode == 0 || targetKeyCode == 59 || targetKeyCode == 62 }

    var isHandsFree: Bool { isHandsFreeMode }

    func start() {
        stop()

        if AXIsProcessTrusted() {
            startWithCGEventTap()
            return
        }

        Log.write("Using NSEvent monitor (CGEventTap unavailable)")
        startWithNSEventMonitor()
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil; runLoopSource = nil
    }

    // MARK: - NSEvent Monitor

    private func startWithNSEventMonitor() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in self?.handleNSEvent(e) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in self?.handleNSEvent(e); return e }
        Log.write("NSEvent monitors started (keyCode: \(targetKeyCode), modifier: \(isModifierHotkey))")
    }

    private func handleNSEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            let ctrl = event.modifierFlags.contains(.control)
            let cmd = event.modifierFlags.contains(.command)
            handleModifierEvent(ctrl: ctrl, cmd: cmd)
        } else if isModifierHotkey {
            handleControlEvent(pressed: event.modifierFlags.contains(.control), isOtherKey: event.type == .keyDown)
        } else {
            handleRegularNSEvent(event)
        }
    }

    private func handleRegularNSEvent(_ event: NSEvent) {
        if Int(event.keyCode) != targetKeyCode { return }
        if event.type == .keyDown { DispatchQueue.main.async { [weak self] in self?.onKeyDown?() } }
        else if event.type == .keyUp { DispatchQueue.main.async { [weak self] in self?.onKeyUp?() } }
    }

    // MARK: - CGEventTap

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var targetKeyIsDown = false

    private func startWithCGEventTap() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return mgr.handleCGEvent(type: type, event: event)
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
        Log.write("CGEventTap started (keyCode: \(targetKeyCode))")
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        if isModifierHotkey {
            let ctrl = event.flags.contains(.maskControl)
            let cmd = event.flags.contains(.maskCommand)
            if type == .flagsChanged {
                handleModifierEvent(ctrl: ctrl, cmd: cmd)
            } else if type == .keyDown && controlIsDown {
                handleControlEvent(pressed: ctrl, isOtherKey: true)
            }
        } else {
            let kc = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if kc == targetKeyCode {
                if type == .keyDown && !targetKeyIsDown {
                    targetKeyIsDown = true
                    DispatchQueue.main.async { [weak self] in self?.onKeyDown?() }
                    return nil
                } else if type == .keyUp && targetKeyIsDown {
                    targetKeyIsDown = false
                    DispatchQueue.main.async { [weak self] in self?.onKeyUp?() }
                    return nil
                }
            }
        }
        return Unmanaged.passRetained(event)
    }

    // MARK: - Modifier routing
    //
    // Ctrl hold           → Push-to-Talk dictation
    // Ctrl double-tap     → Voice Search (starts recording, tap again to stop)
    // Ctrl+Shift hold     → Hands-Free dictation (release when done)

    private var isHandsFreeMode = false
    private var isSearchRecording = false

    private func handleModifierEvent(ctrl: Bool, cmd: Bool) {
        let shift = NSEvent.modifierFlags.contains(.shift)

        // Ctrl+Shift = Hands-Free dictation
        if ctrl && shift && !controlIsDown {
            isHandsFreeMode = true
            controlIsDown = true
            otherKeyPressed = false
            Log.write("HANDS-FREE START (Ctrl+Shift)")
            DispatchQueue.main.async { [weak self] in self?.onKeyDown?() }
            return
        }

        // Released from hands-free
        if isHandsFreeMode && (!ctrl || !shift) {
            isHandsFreeMode = false
            controlIsDown = false
            handsFreeActive = false
            Log.write("HANDS-FREE STOP")
            DispatchQueue.main.async { [weak self] in self?.onKeyUp?() }
            return
        }

        // Normal Ctrl (no Shift, no Cmd)
        if !shift && !cmd {
            handleControlEvent(pressed: ctrl, isOtherKey: false)
        }
    }

    // MARK: - Control key logic
    //
    // The tricky part: we need to distinguish between:
    // 1. Long hold (>0.3s) → push-to-talk dictation (start on press, stop on release)
    // 2. Double-tap (<0.4s between taps) → voice search
    //
    // Solution: On press, DON'T start recording immediately. Wait to see if it's a
    // long hold (start dictation after 0.3s) or a quick tap (potential double-tap).

    private var holdTimer: DispatchWorkItem?
    private let holdThreshold: TimeInterval = 0.3  // if held longer than this → dictation

    private func handleControlEvent(pressed: Bool, isOtherKey: Bool) {
        if isOtherKey && controlIsDown {
            otherKeyPressed = true
            return
        }

        let now = ProcessInfo.processInfo.systemUptime

        if pressed && !controlIsDown {
            controlIsDown = true
            otherKeyPressed = false
            pushStartTime = now

            // Check if this is a double-tap (second press within window)
            if now - lastCtrlReleaseTime < doubleTapWindow && lastCtrlReleaseTime > 0 {
                // DOUBLE TAP → Voice Search mode
                holdTimer?.cancel()
                holdTimer = nil
                isSearchRecording = true
                lastCtrlReleaseTime = 0
                Log.write("SEARCH: START (double-tap) — hold and speak, release to search")
                DispatchQueue.main.async { [weak self] in self?.onSearchKeyDown?() }
                return
            }

            // Schedule dictation start after hold threshold
            let timer = DispatchWorkItem { [weak self] in
                guard let self, self.controlIsDown else { return }
                Log.write("DICTATION: START (hold)")
                DispatchQueue.main.async { self.onKeyDown?() }
            }
            holdTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: timer)

        } else if !pressed && controlIsDown {
            controlIsDown = false

            // Search mode: release = stop recording and search
            if isSearchRecording {
                isSearchRecording = false
                Log.write("SEARCH: STOP (released)")
                DispatchQueue.main.async { [weak self] in self?.onSearchKeyUp?() }
                return
            }

            if otherKeyPressed {
                holdTimer?.cancel()
                holdTimer = nil
                return
            }

            let holdDuration = now - pushStartTime

            if holdDuration < holdThreshold {
                // Short tap — cancel dictation timer, remember for potential double-tap
                holdTimer?.cancel()
                holdTimer = nil
                lastCtrlReleaseTime = now
            } else {
                // Long hold release → stop dictation
                holdTimer?.cancel()
                holdTimer = nil
                lastCtrlReleaseTime = 0
                DispatchQueue.main.async { [weak self] in self?.onKeyUp?() }
            }
        }
    }
}
