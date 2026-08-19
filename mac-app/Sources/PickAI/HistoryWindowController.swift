import AppKit
import SwiftUI

/// Hosts HistoryRootView in a real NSWindow. PickAI is a .accessory app (no Dock icon,
/// no regular activation), so opening a window needs an explicit activate + makeKeyAndOrderFront
/// — accessory apps don't get that behavior for free the way regular apps do.
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(rootView: HistoryRootView())
        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.title = "Pick AI History"
        newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        newWindow.setContentSize(NSSize(width: 720, height: 560))
        newWindow.center()
        newWindow.delegate = self
        // sharingType = .none breaks window compositing over some apps (see OverlayPanel.swift) —
        // stays off for reliable visibility.
        // newWindow.sharingType = .none
        window = newWindow

        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
