import AppKit
import ApplicationServices
import FirebaseCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var selectionMonitor: SelectionMonitor?
    private var screenshotHotkeyMonitor: HotkeyMonitor?
    private var selectionHotkeyMonitor: HotkeyMonitor?
    private var healthTimer: Timer?
    private let overlay = OverlayController()
    private let historyWindow = HistoryWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        FirebaseApp.configure()

        // PickAI has no regular window (LSUIElement + .accessory), so AppKit's Automatic
        // Termination considers it idle-eligible and macOS silently kills it in the
        // background — this is why the hotkeys would stop responding after a while.
        ProcessInfo.processInfo.disableAutomaticTermination("PickAI is a background menu bar agent")

        setupStatusItem()
        checkAccessibilityPermission()
        ScreenshotCapture.requestPermissionIfNeeded()

        let monitor = SelectionMonitor { [weak self] text, location in
            self?.overlay.show(text: text, at: location)
        }
        selectionMonitor = monitor

        let screenshotHotkey = HotkeyMonitor(keyCode: 0x01, flags: [.control, .option, .command]) { [weak self] in
            self?.captureAndSolve()
        }
        screenshotHotkey.start()
        screenshotHotkeyMonitor = screenshotHotkey

        // fn+Q: capture whatever text is currently selected and show the popup.
        let selectionHotkey = HotkeyMonitor(keyCode: 0x0C, flags: [.function]) { [weak self] in
            self?.selectionMonitor?.captureCurrentSelection()
        }
        selectionHotkey.start()
        selectionHotkeyMonitor = selectionHotkey

        updateStatusIndicator()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusIndicator() }
        }
    }

    /// True only when Accessibility is granted AND both event taps are actually alive —
    /// this is the real "will the hotkeys respond right now" signal, not just "is the
    /// process running" (a tap can silently fail to (re)create, e.g. after permission
    /// gets revoked, while the app itself keeps running).
    private var isFullyWorking: Bool {
        AXIsProcessTrusted()
            && (screenshotHotkeyMonitor?.isActive ?? false)
            && (selectionHotkeyMonitor?.isActive ?? false)
    }

    private func updateStatusIndicator() {
        let working = isFullyWorking
        statusItem?.button?.title = (working ? " 🟢 Pick AI" : " 🔴 Pick AI")
        statusItem?.button?.toolTip = working
            ? "Pick AI — hotkeys active"
            : "Pick AI — not working. Check Accessibility permission (menu ▸ Open Accessibility Settings…)."
    }

    private func captureAndSolve() {
        let location = NSEvent.mouseLocation
        // Both CGEventTaps live on the main run loop, so any slow synchronous work here
        // (CGDisplayCreateImage + PNG encoding of a full Retina display can take a while
        // under load) risks blocking it past macOS's watchdog threshold — which disables
        // BOTH hotkeys at once, not just this one. Do the capture off-thread instead.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let captured = ScreenshotCapture.captureScreen(around: location) else { return }
            try? captured.pngData.write(to: URL(fileURLWithPath: "/tmp/pickai_last_capture.png"))
            DispatchQueue.main.async {
                self?.overlay.show(imagePNGData: captured.pngData, at: location)
            }
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Pick AI") {
            image.isTemplate = true
            item.button?.image = image
        }
        item.button?.title = " Pick AI"
        item.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.addItem(withTitle: "Wake Pick AI Up Here", action: #selector(wakeUpHere), keyEquivalent: "")
        menu.addItem(withTitle: "Open Pick AI History", action: #selector(openHistoryWindow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        menu.addItem(withTitle: "Open Screen Recording Settings…", action: #selector(openScreenRecordingSettings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Pick AI", action: #selector(quit), keyEquivalent: "q")
        for menuItem in menu.items {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
    }

    private func checkAccessibilityPermission() {
        let options: [CFString: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @objc private func wakeUpHere() {
        captureAndSolve()
    }

    @objc private func openHistoryWindow() {
        historyWindow.show()
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSLog("[PickAI] Quit Pick AI selected from menu — terminating voluntarily")
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // If a future disappearance isn't a crash (no crash report) and isn't preceded by
        // this line, it's neither a manual quit nor a normal termination — that combination
        // is the actual mystery worth digging into further.
        NSLog("[PickAI] applicationWillTerminate")
    }
}
