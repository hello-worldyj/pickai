import AppKit
import ApplicationServices

private final class OverlayPanel: NSPanel {
    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 100),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        // Excludes this window from screenshots, screen recordings, and screen shares
        // (e.g. Cmd+Shift+4, QuickTime, Zoom/Meet screen share) — it's still visible on-screen.
        // The real cause of the earlier "doesn't show up" reports was diagnosed on 2026-08-23 as
        // a collectionBehavior/Space-exclusion bug (see below), not this flag — sharingType was
        // disabled and re-enabled several times chasing the wrong cause before that.
        sharingType = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // .canJoinAllSpaces + .fullScreenAuxiliary is the combination Apple's docs suggest for
        // "float over anything," but in practice it's unreliable: the window ends up excluded
        // from whichever Space has a fullscreen app, which is the *default* exclusion behavior
        // of plain .canJoinAllSpaces — confirmed live on 2026-08-23 (show() ran with
        // isVisible=true while a fullscreen app was frontmost, but the panel only appeared once
        // the user switched away to the desktop Space). Since this panel is shown fresh at a
        // specific point and dismissed on the next click, it doesn't need to persist across
        // Space switches — .moveToActiveSpace jumps it to whatever Space is active at the
        // moment it's ordered front, and .fullScreenAuxiliary lets that include a fullscreen one.
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
final class OverlayController: NSObject {
    private let panel = OverlayPanel()
    private var clickMonitor: Any?
    private var keyMonitor: Any?

    private var conversation: [ChatMessage] = []
    private var activeMode: QueryMode = .answer
    private var currentQuestionText: String?

    private let stack = NSStackView()
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let buttonsRow = NSStackView()
    private let answerButton = NSButton(title: "Answer", target: nil, action: nil)
    private let explainButton = NSButton(title: "Explain", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let resultScrollView = NSScrollView()
    private let resultTextView = NSTextView()
    private let followUpRow = NSStackView()
    private let followUpField = NSTextField()
    private let askButton = NSButton(title: "Ask", target: nil, action: nil)
    private let footerRow = NSStackView()
    private let copyQuestionButton = NSButton(title: "Copy Question", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Answer", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)

    override init() {
        super.init()
        buildUI()
    }

    func show(text: String, at screenPoint: NSPoint) {
        conversation = [.user(text: text)]
        currentQuestionText = text
        previewLabel.stringValue = String(text.prefix(140))
        setState(.choosing)
        position(at: screenPoint)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        installDismissMonitors()
        logVisibility(trigger: "text", at: screenPoint)
    }

    func show(imagePNGData: Data, at screenPoint: NSPoint) {
        conversation = [.user(imagePNGData: imagePNGData)]
        currentQuestionText = nil
        previewLabel.stringValue = "📷 Screenshot captured"
        setState(.choosing)
        position(at: screenPoint)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        installDismissMonitors()
        logVisibility(trigger: "screenshot", at: screenPoint)
    }

    /// The popup has been reported as sometimes not appearing with no other symptom — likely
    /// while the frontmost app is in native fullscreen, where a window can exist and still not
    /// actually be visible if it isn't correctly composited into that fullscreen Space. This
    /// can't be safely reproduced against a live, actively-used screen, so log everything
    /// needed to diagnose it after the fact instead.
    private func logVisibility(trigger: String, at screenPoint: NSPoint) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main
        NSLog(
            "[PickAI] show(\(trigger)) at=\(screenPoint) panelFrame=\(panel.frame) isVisible=\(panel.isVisible) "
                + "isKeyWindow=\(panel.isKeyWindow) screen=\(String(describing: screen?.frame)) "
                + "frontmostAppFullScreen=\(Self.isFrontmostAppFullScreen())"
        )
    }

    /// Queries the frontmost app's focused window via Accessibility rather than anything on
    /// Pick AI's own process — NSApp.presentationOptions only reflects Pick AI's own state,
    /// not whichever other app the user is actually looking at.
    private static func isFrontmostAppFullScreen() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
        let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let window = windowValue else { return false }
        var fullScreenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, "AXFullScreen" as CFString, &fullScreenValue) == .success else {
            return false
        }
        return (fullScreenValue as? Bool) ?? false
    }

    func dismiss() {
        panel.orderOut(nil)
        removeDismissMonitors()
    }

    private enum State {
        case choosing
        case loading
        case result(String)
    }

    private func setState(_ state: State) {
        switch state {
        case .choosing:
            previewLabel.isHidden = false
            buttonsRow.isHidden = false
            spinner.isHidden = true
            spinner.stopAnimation(nil)
            resultScrollView.isHidden = true
            followUpRow.isHidden = true
            footerRow.isHidden = true
        case .loading:
            previewLabel.isHidden = false
            buttonsRow.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
            resultScrollView.isHidden = true
            followUpRow.isHidden = true
            footerRow.isHidden = true
        case .result(let text):
            // Once the answer is in, the recapped question/screenshot preview is just
            // clutter above it — this section should show the answer and nothing else.
            previewLabel.isHidden = true
            buttonsRow.isHidden = true
            spinner.isHidden = true
            spinner.stopAnimation(nil)
            resultScrollView.isHidden = false
            followUpRow.isHidden = false
            footerRow.isHidden = false
            resultTextView.string = text
            followUpField.stringValue = ""
            copyQuestionButton.isHidden = currentQuestionText == nil
        }
        panel.layoutIfNeeded()
        resizeToFitContent()
    }

    private func buildUI() {
        let container = NSVisualEffectView()
        container.material = .popover
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = container

        previewLabel.font = .systemFont(ofSize: 12)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 2

        answerButton.target = self
        answerButton.action = #selector(answerTapped)
        answerButton.bezelStyle = .rounded
        answerButton.keyEquivalent = "\r"

        explainButton.target = self
        explainButton.action = #selector(explainTapped)
        explainButton.bezelStyle = .rounded

        buttonsRow.orientation = .horizontal
        buttonsRow.distribution = .fillEqually
        buttonsRow.spacing = 8
        buttonsRow.addArrangedSubview(answerButton)
        buttonsRow.addArrangedSubview(explainButton)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true

        resultTextView.isEditable = false
        resultTextView.isSelectable = true
        resultTextView.font = .systemFont(ofSize: 13)
        resultTextView.textContainerInset = NSSize(width: 4, height: 4)
        resultTextView.drawsBackground = false

        resultScrollView.documentView = resultTextView
        resultScrollView.hasVerticalScroller = true
        resultScrollView.drawsBackground = false
        resultScrollView.translatesAutoresizingMaskIntoConstraints = false
        resultScrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        resultScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true

        copyQuestionButton.target = self
        copyQuestionButton.action = #selector(copyQuestionTapped)
        copyQuestionButton.bezelStyle = .rounded

        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.bezelStyle = .rounded

        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.bezelStyle = .rounded

        footerRow.orientation = .horizontal
        footerRow.distribution = .fillEqually
        footerRow.spacing = 8
        footerRow.addArrangedSubview(copyQuestionButton)
        footerRow.addArrangedSubview(copyButton)
        footerRow.addArrangedSubview(closeButton)

        followUpField.placeholderString = "Ask a follow-up…"
        followUpField.target = self
        followUpField.action = #selector(askTapped)
        followUpField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        askButton.target = self
        askButton.action = #selector(askTapped)
        askButton.bezelStyle = .rounded
        askButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        followUpRow.orientation = .horizontal
        followUpRow.spacing = 8
        followUpRow.addArrangedSubview(followUpField)
        followUpRow.addArrangedSubview(askButton)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(previewLabel)
        stack.addArrangedSubview(buttonsRow)
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(resultScrollView)
        stack.addArrangedSubview(followUpRow)
        stack.addArrangedSubview(footerRow)

        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            previewLabel.widthAnchor.constraint(equalToConstant: 352),
            buttonsRow.widthAnchor.constraint(equalToConstant: 352),
            resultScrollView.widthAnchor.constraint(equalToConstant: 352),
            followUpRow.widthAnchor.constraint(equalToConstant: 352),
            footerRow.widthAnchor.constraint(equalToConstant: 352),
        ])
    }

    private func resizeToFitContent() {
        let fitting = panel.contentView?.fittingSize ?? NSSize(width: 320, height: 100)
        var frame = panel.frame
        frame.origin.y += frame.size.height - fitting.height
        frame.size = fitting
        panel.setFrame(frame, display: true)
    }

    private func position(at screenPoint: NSPoint) {
        let fitting = panel.contentView?.fittingSize ?? NSSize(width: 320, height: 100)
        var origin = NSPoint(x: screenPoint.x + 12, y: screenPoint.y - fitting.height - 12)

        // NSScreen.main requires a key window to resolve and can be nil while this panel isn't
        // key yet (e.g. right before its first makeKeyAndOrderFront), so fall through to any
        // screen at all rather than leaving origin unclamped.
        let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        if let screen {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - fitting.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - fitting.height - 8)
        }

        panel.setFrame(NSRect(origin: origin, size: fitting), display: true)
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.dismiss()
                return nil
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
    }

    @objc private func answerTapped() {
        activeMode = .answer
        runQuery()
    }

    @objc private func explainTapped() {
        activeMode = .explain
        runQuery()
    }

    @objc private func askTapped() {
        let question = followUpField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        conversation.append(.user(text: question))
        currentQuestionText = question
        runQuery()
    }

    @objc private func copyQuestionTapped() {
        guard let question = currentQuestionText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(question, forType: .string)
    }

    @objc private func copyTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultTextView.string, forType: .string)
    }

    @objc private func closeTapped() {
        dismiss()
    }

    private func runQuery() {
        setState(.loading)
        let messages = conversation
        let mode = activeMode
        Task {
            do {
                let result = try await BackendClient.query(messages: messages, mode: mode)
                conversation.append(.assistant(text: result))
                setState(.result(result))
                // Persistence now happens server-side (backend Worker -> D1/B2) so the app
                // doesn't need to know about it at all — see HistoryWindowController for how
                // that history is browsed from within the app.
            } catch {
                setState(.result("Error: \(error.localizedDescription)"))
            }
        }
    }
}
