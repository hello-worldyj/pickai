import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var selectionMonitor: SelectionMonitor?
    private var screenshotHotkeyMonitor: HotkeyMonitor?
    private var screenshotHotkeyMonitorAlt: HotkeyMonitor?
    private var selectionHotkeyMonitor: HotkeyMonitor?
    private var healthTimer: Timer?
    private let overlay = OverlayController()
    private let historyWindow = HistoryWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // PickAI has no regular window (LSUIElement + .accessory), so AppKit's Automatic
        // Termination considers it idle-eligible and macOS silently kills it in the
        // background — this is why the hotkeys would stop responding after a while.
        ProcessInfo.processInfo.disableAutomaticTermination("PickAI is a background menu bar agent")

        installLaunchAgentIfNeeded()
        setupStatusItem()
        checkAccessibilityPermission()
        ScreenshotCapture.requestPermissionIfNeeded()

        let monitor = SelectionMonitor(
            onSelection: { [weak self] text, location in
                self?.overlay.show(text: text, at: location)
            },
            // No text was actually selected when fn+Q was pressed — fall back to a screenshot
            // around the cursor instead of silently doing nothing, since that's what people
            // expect from a "just show me the popup" hotkey.
            onNoSelection: { [weak self] location in
                self?.captureAndSolve(at: location)
            }
        )
        selectionMonitor = monitor

        // Both combos are bound to the same action — there's real confusion about which one is
        // "the" screenshot shortcut, so support both instead of relying on remembering one.
        let screenshotHotkey = HotkeyMonitor(keyCode: 0x01, flags: [.command, .shift]) { [weak self] in
            self?.captureAndSolve(at: NSEvent.mouseLocation)
        }
        screenshotHotkey.start()
        screenshotHotkeyMonitor = screenshotHotkey

        let screenshotHotkeyAlt = HotkeyMonitor(keyCode: 0x01, flags: [.control, .option, .command]) { [weak self] in
            self?.captureAndSolve(at: NSEvent.mouseLocation)
        }
        screenshotHotkeyAlt.start()
        screenshotHotkeyMonitorAlt = screenshotHotkeyAlt

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
            && (screenshotHotkeyMonitorAlt?.isActive ?? false)
            && (selectionHotkeyMonitor?.isActive ?? false)
    }

    private func updateStatusIndicator() {
        let working = isFullyWorking
        statusItem?.button?.title = (working ? " 🟢 Pick AI" : " 🔴 Pick AI")
        statusItem?.button?.toolTip = working
            ? "Pick AI — hotkeys active"
            : "Pick AI — not working. Check Accessibility permission (menu ▸ Open Accessibility Settings…)."
    }

    private func captureAndSolve(at location: NSPoint) {
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

    /// Self-installs the com.pickai.app LaunchAgent (KeepAlive + a 1s relaunch throttle)
    /// so PickAI reopens almost instantly whenever it's quit or crashes — including on a
    /// friend's Mac after an AirDrop, which has no idea this LaunchAgent is supposed to
    /// exist. Points at wherever THIS running copy actually lives (Bundle.main.bundlePath),
    /// so it's correct whether that's the dev deploy path or wherever someone dragged the
    /// app after unzipping it. Idempotent: only touches launchd if the plist is missing or
    /// stale, since unload+load kills the currently-running process (KeepAlive relaunches
    /// it within ~1s, but there's no reason to do that on every ordinary launch).
    private func installLaunchAgentIfNeeded() {
        let label = "com.pickai.app"
        let binaryPath = Bundle.main.bundlePath + "/Contents/MacOS/PickAI"
        let launchAgentsDir = NSHomeDirectory() + "/Library/LaunchAgents"
        let plistPath = launchAgentsDir + "/\(label).plist"
        let logPath = NSHomeDirectory() + "/Library/Logs/pickai-app.log"

        let desiredPlist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binaryPath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 1,
            "ProcessType": "Interactive",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]

        let fm = FileManager.default
        let existing = fm.contents(atPath: plistPath).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        if let existing, NSDictionary(dictionary: existing) == NSDictionary(dictionary: desiredPlist) {
            return
        }

        do {
            try fm.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: desiredPlist, format: .xml, options: 0)
            if fm.fileExists(atPath: plistPath) {
                let unload = Process()
                unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                unload.arguments = ["unload", plistPath]
                try? unload.run()
                unload.waitUntilExit()
            }
            try data.write(to: URL(fileURLWithPath: plistPath))

            let load = Process()
            load.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            load.arguments = ["load", plistPath]
            try load.run()
            NSLog("[PickAI] Installed/updated LaunchAgent at \(plistPath)")
        } catch {
            NSLog("[PickAI] Failed to install LaunchAgent: \(error)")
        }
    }

    private func checkAccessibilityPermission() {
        let options: [CFString: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @objc private func wakeUpHere() {
        captureAndSolve(at: NSEvent.mouseLocation)
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
