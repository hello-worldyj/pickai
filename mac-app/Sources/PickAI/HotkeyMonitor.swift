import AppKit
import CoreGraphics

/// Uses an active CGEventTap (not a listen-only NSEvent monitor) so the matching
/// keystroke can be swallowed. A listen-only monitor only *observes* the key press —
/// the OS still delivers it to the focused app, which is why fn+Q used to replace
/// the selected text with a literal "q".
final class HotkeyMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var restartWorkItem: DispatchWorkItem?
    private let onTrigger: () -> Void

    private let requiredKeyCode: UInt16
    private let requiredFlags: NSEvent.ModifierFlags

    /// False if the tap was never created (e.g. missing Accessibility permission) or macOS
    /// has disabled it (timeout/user input) and the restart hasn't landed yet.
    var isActive: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    init(keyCode: UInt16 = 0x01, flags: NSEvent.ModifierFlags = [.control, .option, .command], onTrigger: @escaping () -> Void) {
        self.requiredKeyCode = keyCode
        self.requiredFlags = flags
        self.onTrigger = onTrigger
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

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    NSLog("[PickAI] event tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), re-enabling")
                    monitor.reenable()
                    return Unmanaged.passUnretained(cgEvent)
                }

                guard let nsEvent = NSEvent(cgEvent: cgEvent) else {
                    return Unmanaged.passUnretained(cgEvent)
                }

                let flags = nsEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if monitor.matches(keyCode: nsEvent.keyCode, flags: flags) {
                    DispatchQueue.main.async { monitor.onTrigger() }
                    return nil // swallow: don't let it reach the focused app
                }

                return Unmanaged.passUnretained(cgEvent)
            },
            userInfo: refcon
        ) else {
            scheduleRestart()
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard keyCode == requiredKeyCode else { return false }
        return flags.contains(requiredFlags)
    }

    private func reenable() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
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
