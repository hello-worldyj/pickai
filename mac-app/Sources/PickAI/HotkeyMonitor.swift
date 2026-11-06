import AppKit
import CoreGraphics

/// Uses an active CGEventTap (not a listen-only NSEvent monitor) so the matching
/// keystroke can be swallowed. A listen-only monitor only *observes* the key press —
/// the OS still delivers it to the focused app, which is why fn+Q used to replace
/// the selected text with a literal "q".
final class HotkeyMonitor {
    /// One key+modifier combo and the action it fires. A single HotkeyMonitor can own many of
    /// these so all a-z/0-9 shortcuts share ONE CGEventTap per process instead of needing a
    /// separate tap (and separate OS-level event-callback overhead) per key.
    struct Combo {
        let keyCode: UInt16
        let flags: NSEvent.ModifierFlags
        let action: () -> Void
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var restartWorkItem: DispatchWorkItem?
    private let combos: [Combo]

    /// Human-readable tag used in every log line from this instance ("screenshot", "screenshotAlt",
    /// "selection") — with three of these running at once, an unlabeled log line can't say WHICH
    /// one disabled, rebuilt or fired, which made past incidents hard to pin down.
    let name: String

    // Counters surfaced in the periodic log line, so a burst of tap drops shows up as a rate
    // rather than only as isolated lines scattered through the log.
    private(set) var disableCount = 0
    private(set) var triggerCount = 0
    private(set) var rebuildCount = 0
    private(set) var lastDisableReason: String?
    private(set) var lastEventAt: Date?

    /// False if the tap was never created (e.g. missing Accessibility permission) or macOS
    /// has disabled it (timeout/user input) and the restart hasn't landed yet.
    var isActive: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    init(name: String, keyCode: UInt16 = 0x01, flags: NSEvent.ModifierFlags = [.control, .option, .command], onTrigger: @escaping () -> Void) {
        self.name = name
        self.combos = [Combo(keyCode: keyCode, flags: flags, action: onTrigger)]
    }

    init(name: String, combos: [Combo]) {
        self.name = name
        self.combos = combos
    }

    func start() {
        guard eventTap == nil else { return }
        restartWorkItem?.cancel()

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, refcon in
                guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.lastEventAt = Date()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
                    monitor.disableCount += 1
                    monitor.lastDisableReason = reason
                    NSLog("[PickAI] [\(monitor.name)] event tap disabled (\(reason)), re-enabling (disableCount=\(monitor.disableCount))")
                    monitor.reenable()
                    return Unmanaged.passUnretained(cgEvent)
                }

                // Read the raw CGEvent fields instead of allocating an NSEvent per keystroke: this
                // callback runs on the main run loop for EVERY keydown system-wide, and being slow
                // here is what makes macOS disable the tap ("timeout"). The raw flag bits are the
                // same ones NSEvent.ModifierFlags uses.
                let keyCode = UInt16(truncatingIfNeeded: cgEvent.getIntegerValueField(.keyboardEventKeycode))
                let flags = NSEvent.ModifierFlags(rawValue: UInt(cgEvent.flags.rawValue)).intersection(.deviceIndependentFlagsMask)
                if let action = monitor.matchingAction(keyCode: keyCode, flags: flags) {
                    monitor.triggerCount += 1
                    NSLog("[PickAI] [\(monitor.name)] hotkey fired (triggerCount=\(monitor.triggerCount))")
                    DispatchQueue.main.async { action() }
                    return nil // swallow: don't let it reach the focused app
                }

                return Unmanaged.passUnretained(cgEvent)
            },
            userInfo: refcon
        ) else {
            NSLog("[PickAI] [\(name)] CGEvent.tapCreate returned nil (likely missing Accessibility permission), retrying in 1s")
            scheduleRestart()
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[PickAI] [\(name)] tap created and enabled (\(combos.count) combo(s))")
    }

    /// macOS virtual keycodes, fixed per the physical ANSI keyboard layout (not derived from
    /// anything at runtime). Covers every a-z letter, 0-9 digit, the punctuation keys on the ANSI
    /// layout (by their macOS names), and "space" for the redundant-instance fleet. A name rather
    /// than a single Character because "space" and the punctuation names aren't one character.
    static func keyCode(forName name: String) -> UInt16? {
        switch name.lowercased() {
        case "minus": return 0x1B
        case "equal": return 0x18
        case "backslash": return 0x2A
        case "rbracket": return 0x1E
        case "lbracket": return 0x21
        case "semicolon": return 0x29
        case "quote": return 0x27
        case "slash": return 0x2C
        case "period": return 0x2F
        case "comma": return 0x2B
        case "a": return 0x00
        case "b": return 0x0B
        case "c": return 0x08
        case "d": return 0x02
        case "e": return 0x0E
        case "f": return 0x03
        case "g": return 0x05
        case "h": return 0x04
        case "i": return 0x22
        case "j": return 0x26
        case "k": return 0x28
        case "l": return 0x25
        case "m": return 0x2E
        case "n": return 0x2D
        case "o": return 0x1F
        case "p": return 0x23
        case "q": return 0x0C
        case "r": return 0x0F
        case "s": return 0x01
        case "t": return 0x11
        case "u": return 0x20
        case "v": return 0x09
        case "w": return 0x0D
        case "x": return 0x07
        case "y": return 0x10
        case "z": return 0x06
        case "0": return 0x1D
        case "1": return 0x12
        case "2": return 0x13
        case "3": return 0x14
        case "4": return 0x15
        case "5": return 0x17
        case "6": return 0x16
        case "7": return 0x1A
        case "8": return 0x1C
        case "9": return 0x19
        case "space": return 0x31
        default: return nil
        }
    }

    private func matchingAction(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> (() -> Void)? {
        for combo in combos where combo.keyCode == keyCode && flags.contains(combo.flags) {
            return combo.action
        }
        return nil
    }

    private func reenable() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    /// start() no-ops while a tap object exists, so a tap that was created but later went dead
    /// (macOS disabled it and re-enabling didn't stick, or its port was invalidated) would stay
    /// dead forever with hotkeys silently ignored. Tear it down and rebuild it from scratch.
    func restartIfInactive() {
        guard !isActive else { return }
        rebuildCount += 1
        NSLog("[PickAI] [\(name)] tap inactive, rebuilding (rebuildCount=\(rebuildCount) lastDisableReason=\(lastDisableReason ?? "none") lastEventAt=\(lastEventAt.map(String.init(describing:)) ?? "never"))")
        stop()
        start()
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        restartWorkItem?.cancel()
        restartWorkItem = nil
    }

    private func scheduleRestart() {
        restartWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.start()
        }
        restartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    deinit {
        stop()
    }
}
