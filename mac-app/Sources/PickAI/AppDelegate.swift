import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    /// The instance's own label ("Pick AI" for main, bare "d"/"z"/.../"space" for a redundant
    /// instance) — stored separately from the 🟢/🔴 prefix so updateStatusIndicator can refresh
    /// the health dot every 3s without stomping the per-instance name back to a hardcoded
    /// "Pick AI" (that's exactly what it was doing before this was split out).
    private var statusItemBaseTitle = " Pick AI"
    private var selectionMonitor: SelectionMonitor?
    // All of this process's CGEventTap hotkeys, main or redundant — logStatusLine,
    // isFullyWorking, updateStatusIndicator and rebuildAllHotkeys all just walk this array,
    // so a redundant instance (one single entry) and the main instance (two entries) share
    // the same health-check/self-heal code without the three-named-optionals plumbing that
    // only fit the main instance's fixed shape.
    private var hotkeyMonitors: [HotkeyMonitor] = []
    /// nil until the first check runs; after that, sticks to the last value actually written to
    /// the status item so updateStatusIndicator (every 3s, across all 11 processes at once) can
    /// skip the write entirely when nothing changed. Writing it unconditionally every tick is
    /// what was flooding Dock with menu-bar-extra updates on 2026-10-06 (see the "workspace
    /// client connection invalidated" SIGKILLs that morning) — the health state is "working"
    /// the overwhelming majority of ticks, so almost all of those writes were wasted no-ops.
    private var lastShownWorkingState: Bool?
    private var healthTimer: Timer?
    private var heartbeatTimer: Timer?
    private let overlay = OverlayController()
    private let historyWindow = HistoryWindowController()
    private let launchedAt = Date()

    /// Set only on a redundant instance (via its LaunchAgent's EnvironmentVariables, read back
    /// here) — a key name ("d", "minus", ... "space"), naming which key this whole separate OS
    /// process exists to own. nil means this is the main instance.
    private var redundantKeyName: String? {
        ProcessInfo.processInfo.environment["PICKAI_HOTKEY_NAME"]
    }

    /// "selection" on a clone that owns fn+<key> (capture selected text); nil on one that owns
    /// ⌃⌥⌘+<key> (screenshot-and-solve). Read the same way as redundantKeyName.
    private var redundantKindIsSelection: Bool {
        ProcessInfo.processInfo.environment["PICKAI_HOTKEY_KIND"] == "selection"
    }

    /// Every key that has clones: the full keyboard as listed by the user, with space last. Each
    /// key gets two clones — one for ⌃⌥⌘+<key>, one for fn+<key> — so 47 keys = 94 clone processes.
    /// Symbol keys use their macOS names, since LaunchAgent labels and environment values need them.
    private static let cloneKeys = [
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "minus", "equal", "backslash", "rbracket", "lbracket",
        "p", "o", "i", "u", "y", "t", "r", "e", "w", "q",
        "a", "s", "d", "f", "g", "h", "j", "k", "l", "semicolon", "quote", "slash", "period", "comma",
        "m", "n", "b", "v", "c", "x", "z",
        "space",
    ]

    /// Every clone's LaunchAgent label and environment, toggled on/off together from the menu.
    /// The ⌃⌥⌘ clones keep the label older installs already use, so they aren't reinstalled.
    private static let clones: [(label: String, environment: [String: String])] = cloneKeys.flatMap { key in
        [
            ("com.pickai.redundant.\(key)", ["PICKAI_HOTKEY_NAME": key]),
            ("com.pickai.redundant.fn.\(key)", ["PICKAI_HOTKEY_NAME": key, "PICKAI_HOTKEY_KIND": "selection"]),
        ]
    }

    /// How a clone's key shows up in the menu bar — symbol keys get their character, the rest their
    /// name, with "space" as ⎵ since the word would be the widest item in the bar.
    private static func menuTitle(forKey key: String, selection: Bool) -> String {
        let symbols = [
            "space": "⎵", "minus": "-", "equal": "=", "backslash": "\\", "rbracket": "]", "lbracket": "[",
            "semicolon": ";", "quote": "'", "slash": "/", "period": ".", "comma": ",",
        ]
        let base = symbols[key] ?? key
        return selection ? "fn \(base)" : base
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // PickAI has no regular window (LSUIElement + .accessory), so AppKit's Automatic
        // Termination considers it idle-eligible and macOS silently kills it in the
        // background — this is why the hotkeys would stop responding after a while.
        ProcessInfo.processInfo.disableAutomaticTermination("PickAI is a background menu bar agent")
        checkAccessibilityPermission()
        ScreenshotCapture.requestPermissionIfNeeded()

        if let name = redundantKeyName {
            setupRedundantInstance(keyName: name)
        } else {
            setupMainInstance()
        }

        logStatusLine(event: "launched")

        updateStatusIndicator()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusIndicator() }
        }

        // A full status dump every 5 minutes, independent of anything going wrong: if PickAI is
        // silently killed, the LAST line this produces before the gap pins down the time window
        // precisely, and its absence (vs. an orderly quit/terminate line) is itself the evidence
        // that it wasn't a normal exit.
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.logStatusLine(event: "heartbeat") }
        }

        // A tap can report "enabled" yet stop receiving events after the machine sleeps or the
        // login session changes hands, which the 3s check can't see. Rebuild from scratch then.
        // Each notification logged under its own name instead of a shared "system state change" —
        // sleep/wake and login-session handoff are different failure modes worth telling apart.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let wakeReasons: [(Notification.Name, String)] = [
            (NSWorkspace.didWakeNotification, "display/machine wake"),
            (NSWorkspace.screensDidWakeNotification, "screens woke"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "login session became active"),
        ]
        for (notificationName, reason) in wakeReasons {
            workspaceCenter.addObserver(forName: notificationName, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rebuildAllHotkeys(reason: reason) }
            }
        }
        // These don't rebuild anything — they're purely to narrow down a silent-kill window if
        // one happens right around a sleep/lock, which 9/22's incident may have been.
        let observeOnly: [(Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, "will sleep"),
            (NSWorkspace.sessionDidResignActiveNotification, "login session resigned active"),
            (NSWorkspace.screensDidSleepNotification, "screens slept"),
        ]
        for (notificationName, reason) in observeOnly {
            workspaceCenter.addObserver(forName: notificationName, object: nil, queue: .main) { _ in
                NSLog("[PickAI] system event: \(reason)")
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in NSLog("[PickAI] system event: screen locked") }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { _ in NSLog("[PickAI] system event: screen unlocked") }
    }

    /// The main instance: only cmd+shift+S. Every other hotkey belongs to a clone process (one
    /// per key and combo, see Self.clones), so main never fires on a combo a clone also owns.
    private func setupMainInstance() {
        installLaunchAgentIfNeeded()
        setupStatusItem(includeCloneControls: true)

        let screenshotHotkey = HotkeyMonitor(name: "screenshot", keyCode: 0x01, flags: [.command, .shift]) { [weak self] in
            self?.captureAndSolve(at: NSEvent.mouseLocation)
        }
        screenshotHotkey.start()

        hotkeyMonitors = [screenshotHotkey]
    }

    /// One whole separate OS process per combo, each with its own LaunchAgent (so its own KeepAlive
    /// restart, independent of every other instance's) and its own CGEventTap. ⌃⌥⌘+<key> clones
    /// do screenshot-and-solve; fn+<key> clones do capture-selected-text. If one gets stuck while
    /// still running, every other clone is unaffected, so the rest of the combos keep working.
    private func setupRedundantInstance(keyName: String) {
        guard let code = HotkeyMonitor.keyCode(forName: keyName) else {
            NSLog("[PickAI] redundant instance given unrecognized PICKAI_HOTKEY_NAME '\(keyName)' — exiting")
            NSApp.terminate(nil)
            return
        }
        let isSelection = redundantKindIsSelection
        let label = isSelection ? "com.pickai.redundant.fn.\(keyName)" : "com.pickai.redundant.\(keyName)"
        let environment = isSelection
            ? ["PICKAI_HOTKEY_NAME": keyName, "PICKAI_HOTKEY_KIND": "selection"]
            : ["PICKAI_HOTKEY_NAME": keyName]
        installLaunchAgentIfNeeded(label: label, environment: environment)
        // includeCloneControls: true here too — every clone gets the exact same menu as the main
        // instance (clone open/close controls, settings, history, etc.), not a stripped-down one.
        setupStatusItem(title: Self.menuTitle(forKey: keyName, selection: isSelection), showIcon: false, includeCloneControls: true)

        if isSelection {
            selectionMonitor = makeSelectionMonitor()
            let monitor = HotkeyMonitor(name: "redundant-fn-\(keyName)", keyCode: code, flags: [.function]) { [weak self] in
                self?.selectionMonitor?.captureCurrentSelection()
            }
            monitor.start()
            hotkeyMonitors = [monitor]
        } else {
            let monitor = HotkeyMonitor(name: "redundant-\(keyName)", keyCode: code, flags: [.command, .option, .control]) { [weak self] in
                self?.captureAndSolve(at: NSEvent.mouseLocation)
            }
            monitor.start()
            hotkeyMonitors = [monitor]
        }
    }

    /// Shared by main and every clone: fn+<key> (and fn+Q on main) reads the selected text, and
    /// falls back to a screenshot around the cursor when nothing is selected.
    private func makeSelectionMonitor() -> SelectionMonitor {
        SelectionMonitor(
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
    }

    /// One line giving the full picture at once (uptime, permission, every tap's own counters) —
    /// grepping "[PickAI]" used to turn up dozens of lines you had to mentally stitch back
    /// together per monitor; this gives the same picture in one line, at startup, every 5 minutes,
    /// and right before a rebuild. All instances (main and redundant) share this log file, so
    /// every line is tagged with its own pid and tap name(s) to tell them apart.
    private func logStatusLine(event: String) {
        let uptime = Int(Date().timeIntervalSince(launchedAt))
        let perTap = hotkeyMonitors.map { tap in
            "\(tap.name)(active=\(tap.isActive) triggers=\(tap.triggerCount) disables=\(tap.disableCount) rebuilds=\(tap.rebuildCount))"
        }.joined(separator: " ")
        let instance = redundantKeyName.map { "redundant-\($0)" } ?? "main"
        NSLog("[PickAI] \(event) instance=\(instance) pid=\(ProcessInfo.processInfo.processIdentifier) uptimeSec=\(uptime) accessibilityTrusted=\(AXIsProcessTrusted()) \(perTap)")
    }

    private func rebuildAllHotkeys(reason: String) {
        NSLog("[PickAI] rebuilding hotkey taps (\(reason))")
        logStatusLine(event: "pre-rebuild")
        for monitor in hotkeyMonitors {
            monitor.stop()
            monitor.start()
        }
    }

    /// True only when Accessibility is granted AND every one of this process's taps is actually
    /// alive — this is the real "will the hotkeys respond right now" signal, not just "is the
    /// process running" (a tap can silently fail to (re)create, e.g. after permission
    /// gets revoked, while the app itself keeps running).
    private var isFullyWorking: Bool {
        AXIsProcessTrusted() && hotkeyMonitors.allSatisfy { $0.isActive }
    }

    private func updateStatusIndicator() {
        // Self-heal, don't just report: a dead tap used to only turn the icon red and stay
        // dead until the user quit and reopened the app by hand. restartIfInactive() itself
        // logs the rebuild with that tap's counters, so no extra logging needed here.
        for monitor in hotkeyMonitors {
            monitor.restartIfInactive()
        }
        let working = isFullyWorking
        guard working != lastShownWorkingState else { return }
        lastShownWorkingState = working
        statusItem?.button?.title = (working ? "🟢" : "🔴") + statusItemBaseTitle
        statusItem?.button?.toolTip = working
            ? "Pick AI — hotkeys active"
            : "Pick AI — not working. Check Accessibility permission (menu ▸ Open Accessibility Settings…)."
    }

    private func captureAndSolve(at location: NSPoint) {
        // Both CGEventTaps live on the main run loop, so any slow synchronous work here
        // (CGDisplayCreateImage + PNG encoding of a full Retina display can take a while
        // under load) risks blocking it past macOS's watchdog threshold — which disables
        // BOTH hotkeys at once, not just this one. Do the capture off-thread instead.
        let startedAt = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let captured = ScreenshotCapture.captureScreen(around: location) else {
                NSLog("[PickAI] captureAndSolve: ScreenshotCapture returned nil (permission denied or no display at \(location)?)")
                return
            }
            let captureMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            if captureMs > 500 {
                // Anything this slow is a candidate for the next watchdog-timeout tap disable,
                // since both CGEventTaps share this same main-thread-adjacent budget.
                NSLog("[PickAI] captureAndSolve: slow capture took \(captureMs)ms at \(location)")
            }
            try? captured.pngData.write(to: URL(fileURLWithPath: "/tmp/pickai_last_capture.png"))
            DispatchQueue.main.async {
                self?.overlay.show(imagePNGData: captured.pngData, at: location)
            }
        }
    }

    private func setupStatusItem(title: String = " Pick AI", showIcon: Bool = true, includeCloneControls: Bool = false) {
        statusItemBaseTitle = title
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // macOS has no overflow drawer for third-party menu-bar items — once the bar runs out
        // of width, extras just get pushed off-screen and become invisible (not removed, just
        // unreachable). With 10 of these at once, dropping the icon on the 9 redundant ones
        // (bare key-letter text only) is the difference between most of them fitting and most
        // of them not — they keep working as hotkeys either way, this only affects what's visible.
        if showIcon, let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Pick AI") {
            image.isTemplate = true
            item.button?.image = image
        }
        item.button?.title = title
        item.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.addItem(withTitle: "Wake Pick AI Up Here", action: #selector(wakeUpHere), keyEquivalent: "")
        menu.addItem(withTitle: "Open Pick AI History", action: #selector(openHistoryWindow), keyEquivalent: "")
        menu.addItem(.separator())
        if includeCloneControls {
            menu.addItem(withTitle: "Open Pick AI Clones…", action: #selector(promptToOpenClones), keyEquivalent: "")
            menu.addItem(withTitle: "Close Pick AI Clones", action: #selector(closeClones), keyEquivalent: "")
            menu.addItem(.separator())
        }
        let hideFromScreenshotsItem = NSMenuItem(
            title: "Hide Popup From Screenshots", action: #selector(toggleHideFromScreenshots), keyEquivalent: ""
        )
        hideFromScreenshotsItem.state = PickAISettings.hideFromScreenshots ? .on : .off
        menu.addItem(hideFromScreenshotsItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        menu.addItem(withTitle: "Open Screen Recording Settings…", action: #selector(openScreenRecordingSettings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Pick AI", action: #selector(quit), keyEquivalent: "q")
        for menuItem in menu.items {
            menuItem.target = self
        }
        // Keeps the checkmark correct even when this setting was toggled from a DIFFERENT Pick AI
        // process's menu (main or any clone) — all of them share the same UserDefaults-backed
        // PickAISettings, so re-read it right before the menu is actually shown rather than only
        // once at menu-build time.
        menu.delegate = self
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
    private func installLaunchAgentIfNeeded(label: String = "com.pickai.app", environment: [String: String] = [:]) {
        let binaryPath = Bundle.main.bundlePath + "/Contents/MacOS/PickAI"
        let launchAgentsDir = NSHomeDirectory() + "/Library/LaunchAgents"
        let plistPath = launchAgentsDir + "/\(label).plist"
        // Shared log file across the main instance and every redundant instance — each line is
        // already tagged with its own pid and instance name (see logStatusLine), so one file
        // stays greppable instead of needing to check eleven separate log files.
        let logPath = NSHomeDirectory() + "/Library/Logs/pickai-app.log"

        var desiredPlist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binaryPath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 1,
            "ProcessType": "Interactive",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        if !environment.isEmpty {
            // This is what tells a redundant instance which single ⌃⌥⌘+<char> combo it owns —
            // launchd hands it back as this process's environment on every relaunch, so the
            // assignment survives crashes/restarts without needing to be stored anywhere else.
            desiredPlist["EnvironmentVariables"] = environment
        }

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

    /// Loads a LaunchAgent that is on disk but not currently registered with launchd. `launchctl list
    /// <label>` exits non-zero when the label isn't loaded.
    private func loadLaunchAgentIfNotLoaded(label: String) {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        check.arguments = ["list", label]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        guard (try? check.run()) != nil else { return }
        check.waitUntilExit()
        guard check.terminationStatus != 0 else { return }

        let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
        let load = Process()
        load.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        load.arguments = ["load", plistPath]
        try? load.run()
        load.waitUntilExit()
        NSLog("[PickAI] loaded LaunchAgent \(label)")
    }

    private func checkAccessibilityPermission() {
        let options: [CFString: Any] = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items where item.action == #selector(toggleHideFromScreenshots) {
            item.state = PickAISettings.hideFromScreenshots ? .on : .off
        }
    }

    @objc private func toggleHideFromScreenshots() {
        PickAISettings.hideFromScreenshots.toggle()
        NSLog("[PickAI] hideFromScreenshots set to \(PickAISettings.hideFromScreenshots)")
    }

    @objc private func wakeUpHere() {
        captureAndSolve(at: NSEvent.mouseLocation)
    }

    /// Installs (or reinstalls) every clone's own LaunchAgent — each is RunAtLoad + KeepAlive,
    /// so this both starts them now and makes them survive reboots until explicitly closed.
    @objc private func promptToOpenClones() {
        let alert = NSAlert()
        alert.messageText = "Open Pick AI Clones"
        alert.informativeText = "How many clones would you like to open? Choose a number from 1 to \(Self.clones.count)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Clones")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(string: "10")
        input.placeholderString = "1–\(Self.clones.count)"
        input.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        input.alignment = .center
        input.focusRingType = .default
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requestedCount = Int(value), (1...Self.clones.count).contains(requestedCount) else {
            let error = NSAlert()
            error.messageText = "Enter a number from 1 to \(Self.clones.count)."
            error.alertStyle = .warning
            error.addButton(withTitle: "OK")
            error.runModal()
            return
        }

        openClones(count: requestedCount)
    }

    private func openClones(count requestedCount: Int) {
        let clonesToOpen = Array(Self.clones.prefix(min(requestedCount, Self.clones.count)))
        for clone in clonesToOpen {
            installLaunchAgentIfNeeded(label: clone.label, environment: clone.environment)
            // installLaunchAgentIfNeeded only loads a plist it had to (re)write, so a clone whose
            // plist already matched but was unloaded would otherwise stay closed after this click.
            loadLaunchAgentIfNotLoaded(label: clone.label)
        }
        NSLog("[PickAI] opened Pick AI clones (\(clonesToOpen.count))")
    }

    /// Unloads AND removes each clone's plist — removing it (not just unloading) is what keeps
    /// them closed across a reboot too, since installLaunchAgentIfNeeded only reinstalls one
    /// that's missing or stale, and a future "Open Pick AI Clones" click re-creates it fresh.
    @objc private func closeClones() {
        let launchAgentsDir = NSHomeDirectory() + "/Library/LaunchAgents"
        for clone in Self.clones {
            let plistPath = launchAgentsDir + "/\(clone.label).plist"
            guard FileManager.default.fileExists(atPath: plistPath) else { continue }
            let unload = Process()
            unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            unload.arguments = ["unload", plistPath]
            try? unload.run()
            unload.waitUntilExit()
            try? FileManager.default.removeItem(atPath: plistPath)
        }
        NSLog("[PickAI] closed all Pick AI clones (\(Self.clones.count))")
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
        // is the actual mystery worth digging into further. The full status line here (not just
        // the bare message the old version logged) means even an unplanned termination leaves
        // behind the tap counters from right before it died.
        logStatusLine(event: "applicationWillTerminate")
    }
}
