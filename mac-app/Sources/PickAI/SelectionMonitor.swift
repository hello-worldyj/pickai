import AppKit

final class SelectionMonitor {
    private let onSelection: (String, NSPoint) -> Void

    private let pollInterval: TimeInterval = 0.05
    private let maxPollAttempts = 6
    private let maxTextLength = 8000

    init(onSelection: @escaping (String, NSPoint) -> Void) {
        self.onSelection = onSelection
    }

    /// Copies whatever is currently selected in the frontmost app and shows the popup.
    /// Triggered manually (e.g. via hotkey) rather than automatically on drag, so normal
    /// drag-to-select/copy-paste in other apps isn't hijacked.
    func captureCurrentSelection() {
        captureSelection(at: NSEvent.mouseLocation)
    }

    private func captureSelection(at location: NSPoint) {
        let pasteboard = NSPasteboard.general
        let previousChangeCount = pasteboard.changeCount
        let savedItems = Self.snapshot(of: pasteboard)

        simulateCopyKeystroke()
        pollForChange(previousChangeCount: previousChangeCount, savedItems: savedItems, location: location, attempt: 0)
    }

    private func pollForChange(previousChangeCount: Int, savedItems: [NSPasteboardItem], location: NSPoint, attempt: Int) {
        let pasteboard = NSPasteboard.general

        if pasteboard.changeCount != previousChangeCount {
            let capturedText = pasteboard.string(forType: .string)
            Self.restore(savedItems, to: pasteboard)

            if let capturedText, !capturedText.isEmpty {
                onSelection(String(capturedText.prefix(maxTextLength)), location)
            }
            return
        }

        guard attempt < maxPollAttempts else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            self?.pollForChange(previousChangeCount: previousChangeCount, savedItems: savedItems, location: location, attempt: attempt + 1)
        }
    }

    private func simulateCopyKeystroke() {
        let source = CGEventSource(stateID: .hidSystemState)
        let virtualKeyC: CGKeyCode = 0x08 // kVK_ANSI_C
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyC, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyC, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
