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
        // sharingType = .none excludes this window from screenshots/screen recordings (Cmd+Shift+4,
        // QuickTime, Zoom/Meet share, etc.) so Pick AI doesn't capture itself. User-toggleable via
        // the menu bar "Hide Popup From Screenshots" item (see AppDelegate/PickAISettings) — applied
        // fresh on every show() too, so a toggle from any Pick AI process (main or a clone) takes
        // effect immediately rather than only on next launch.
        sharingType = PickAISettings.hideFromScreenshots ? .none : .readOnly
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
    private let spinner = NSProgressIndicator()
    private var fullWidthConstraints: [NSLayoutConstraint] = []
    private let reasoningLabel = NSTextField(labelWithString: "Reasoning")
    private let reasoningScrollView = NSScrollView()
    private let reasoningTextView = NSTextView()
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
        applyScreenshotVisibilitySetting()
        conversation = [.user(text: text)]
        currentQuestionText = text
        previewLabel.stringValue = String(text.prefix(140))
        // No more "Answer or Explain?" choosing step — that whole row only existed to pick a
        // mode, and with Explain gone there's nothing left to choose, so go straight to loading.
        activeMode = .answer
        setState(.loading)
        position(at: screenPoint)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        installDismissMonitors()
        logVisibility(trigger: "text", at: screenPoint)
        runQuery()
    }

    func show(imagePNGData: Data, at screenPoint: NSPoint) {
        applyScreenshotVisibilitySetting()
        conversation = [.user(imagePNGData: imagePNGData)]
        currentQuestionText = nil
        previewLabel.stringValue = "📷 Screenshot captured"
        activeMode = .answer
        setState(.loading)
        position(at: screenPoint)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        installDismissMonitors()
        logVisibility(trigger: "screenshot", at: screenPoint)
        runQuery()
    }

    /// The popup has been reported as sometimes not appearing with no other symptom — likely
    /// while the frontmost app is in native fullscreen, where a window can exist and still not
    /// actually be visible if it isn't correctly composited into that fullscreen Space. This
    /// can't be safely reproduced against a live, actively-used screen, so log everything
    /// needed to diagnose it after the fact instead.
    private func logVisibility(trigger: String, at screenPoint: NSPoint) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main
        let panelFrame = panel.frame
        let isVisible = panel.isVisible
        let isKeyWindow = panel.isKeyWindow
        let screenFrame = screen?.frame
        // isFrontmostAppFullScreen() makes a synchronous cross-process Accessibility call, which
        // can block for a long time if the frontmost app is slow to respond. This runs on the same
        // main run loop as PickAI's globally head-inserted CGEventTaps (all system keydown events
        // funnel through them first) — a stall here previously froze system-wide keyboard input
        // until macOS's tap watchdog kicked in (confirmed via repeated "event tap disabled (timeout)"
        // log lines during a real freeze). Dispatch off the main thread since this is diagnostic-only.
        DispatchQueue.global(qos: .utility).async {
            let frontmostAppFullScreen = Self.isFrontmostAppFullScreen()
            NSLog(
                "[PickAI] show(\(trigger)) at=\(screenPoint) panelFrame=\(panelFrame) isVisible=\(isVisible) "
                    + "isKeyWindow=\(isKeyWindow) screen=\(String(describing: screenFrame)) "
                    + "frontmostAppFullScreen=\(frontmostAppFullScreen)"
            )
        }
    }

    /// Queries the frontmost app's focused window via Accessibility rather than anything on
    /// Pick AI's own process — NSApp.presentationOptions only reflects Pick AI's own state,
    /// not whichever other app the user is actually looking at.
    private nonisolated static func isFrontmostAppFullScreen() -> Bool {
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

    private func applyScreenshotVisibilitySetting() {
        panel.sharingType = PickAISettings.hideFromScreenshots ? .none : .readOnly
    }

    func dismiss() {
        panel.orderOut(nil)
        removeDismissMonitors()
    }

    private enum State {
        case loading
        case result(reasoning: String, answer: String)
    }

    // The fittingSize-based auto-shrink approach never produced a small loading panel in
    // practice (NSStackView/Auto Layout fittingSize didn't collapse reliably even with hidden
    // siblings and a lessThanOrEqualTo trailing constraint). Loading now gets an explicit,
    // hardcoded small size instead of asking Auto Layout to infer one.
    private static let loadingSize = NSSize(width: 44, height: 44)
    private var currentContentSize = NSSize(width: 320, height: 100)

    private func setState(_ state: State) {
        switch state {
        case .loading:
            previewLabel.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
            reasoningLabel.isHidden = true
            reasoningScrollView.isHidden = true
            resultScrollView.isHidden = true
            followUpRow.isHidden = true
            footerRow.isHidden = true
            NSLayoutConstraint.deactivate(fullWidthConstraints)
            currentContentSize = Self.loadingSize
        case .result(let reasoning, let answer):
            NSLayoutConstraint.activate(fullWidthConstraints)
            // Once the answer is in, the recapped question/screenshot preview is just
            // clutter above it — this section should show the reasoning (when the backend sent
            // any) and the answer and nothing else.
            previewLabel.isHidden = true
            spinner.isHidden = true
            spinner.stopAnimation(nil)
            let hasReasoning = !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            reasoningLabel.isHidden = !hasReasoning
            reasoningScrollView.isHidden = !hasReasoning
            reasoningTextView.string = reasoning
            resultScrollView.isHidden = false
            followUpRow.isHidden = false
            footerRow.isHidden = false
            resultTextView.string = answer
            followUpField.stringValue = ""
            copyQuestionButton.isHidden = currentQuestionText == nil
            panel.layoutIfNeeded()
            currentContentSize = panel.contentView?.fittingSize ?? NSSize(width: 320, height: 100)
        }
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

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true

        reasoningLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        reasoningLabel.textColor = .secondaryLabelColor

        reasoningTextView.isEditable = false
        reasoningTextView.isSelectable = true
        reasoningTextView.font = .systemFont(ofSize: 12)
        reasoningTextView.textColor = .secondaryLabelColor
        reasoningTextView.textContainerInset = NSSize(width: 4, height: 4)
        reasoningTextView.drawsBackground = false

        reasoningScrollView.documentView = reasoningTextView
        reasoningScrollView.hasVerticalScroller = true
        reasoningScrollView.drawsBackground = false
        reasoningScrollView.translatesAutoresizingMaskIntoConstraints = false
        reasoningScrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true
        reasoningScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true

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
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(reasoningLabel)
        stack.addArrangedSubview(reasoningScrollView)
        stack.addArrangedSubview(resultScrollView)
        stack.addArrangedSubview(followUpRow)
        stack.addArrangedSubview(footerRow)

        container.addSubview(stack)

        fullWidthConstraints = [
            previewLabel.widthAnchor.constraint(equalToConstant: 352),
            reasoningScrollView.widthAnchor.constraint(equalToConstant: 352),
            resultScrollView.widthAnchor.constraint(equalToConstant: 352),
            followUpRow.widthAnchor.constraint(equalToConstant: 352),
            footerRow.widthAnchor.constraint(equalToConstant: 352),
        ]
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            // lessThanOrEqualTo (not equalTo) so the container shrinks to the spinner in loading
            // state when fullWidthConstraints are inactive, rather than stretching to fill the panel.
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
        ])
    }

    private func resizeToFitContent() {
        var frame = panel.frame
        frame.origin.y += frame.size.height - currentContentSize.height
        frame.size = currentContentSize
        panel.setFrame(frame, display: true)
    }

    private func position(at screenPoint: NSPoint) {
        let size = currentContentSize
        var origin = NSPoint(x: screenPoint.x + 12, y: screenPoint.y - size.height - 12)

        // NSScreen.main requires a key window to resolve and can be nil while this panel isn't
        // key yet (e.g. right before its first makeKeyAndOrderFront), so fall through to any
        // screen at all rather than leaving origin unclamped.
        let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        if let screen {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
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
                let response = try await BackendClient.query(messages: messages, mode: mode)
                // Only the final answer goes back into the conversation — the reasoning is
                // shown once in the popup, not replayed to the model on every follow-up turn.
                conversation.append(.assistant(text: response.result))
                let isMC = CapsLockBlinker.isMultipleChoiceAnswer(response.result)
                NSLog("[PickAI] MC detection: isMC=\(isMC) result='\(response.result.prefix(80))'")
                if isMC {
                    // Silent mode: dismiss the overlay and signal the answer via Caps Lock LED blinks.
                    dismiss()
                    CapsLockBlinker.scheduleForAnswer(response.result)
                    return
                }
                setState(.result(reasoning: response.reasoning, answer: response.result))
                // Persistence now happens server-side (backend Worker -> D1/B2) so the app
                // doesn't need to know about it at all — see HistoryWindowController for how
                // that history is browsed from within the app.
            } catch {
                setState(.result(reasoning: "", answer: "Error: \(error.localizedDescription)"))
            }
        }
    }
}
