import AppKit
import SwiftUI

/// The box's window: a borderless non-activating floating panel that
/// hosts `BoxView` and follows its height (docs/research/system-integration.md
/// §4). Created once at launch and kept, so `show` is a frame change and
/// an order-front: well inside the 100 ms budget. The source app keeps
/// focus; the panel becomes key so the input takes typing.
final class BoxPanel: NSPanel {
    let model: BoxModel
    private let host: NSHostingView<AnyView>
    private weak var inputField: InputField?
    private var anchor: BoxAnchor?
    /// When the box last came up: activation churn right after showing
    /// (the panel taking key can activate this app for a moment) is not a
    /// reason to close it.
    private var shownAt: Date?
    private var mouseMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    init(model: BoxModel) {
        self.model = model
        let box = BoxView(model: model, registerInput: nil)
        host = NSHostingView(rootView: AnyView(box))
        super.init(contentRect: NSRect(x: 0, y: 0, width: Theme.Box.width, height: 120),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        // The card draws its own material, radius and hairline; the window
        // is clear and carries only its shadow.
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        host.rootView = AnyView(BoxView(model: model,
                                        registerInput: { [weak self] field in self?.inputField = field },
                                        onSize: { [weak self] size in self?.cardDidLayout(size) }))
        // The panel sizes itself (refit): the hosting view's own sizing fought it.
        host.sizingOptions = []
        contentView = host
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        })
        observeModel()
        // Switching apps or clicking elsewhere closes the box; observed once, acted on only while visible.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.isVisible, self.settled else { return }
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                // Neither this app taking key nor the source app re-activating is a switch away.
                if let app, app.processIdentifier == NSRunningApplication.current.processIdentifier { return }
                if let app, app.processIdentifier == self.model.selection.sourceApp?.pid { return }
                self.model.onClose()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible, self.settled else { return }
                self.model.onClose()
            }
        })
    }

    /// Half a second after showing, activation changes mean the user left.
    private var settled: Bool {
        guard let shownAt else { return true }
        return Date().timeIntervalSince(shownAt) > 0.5
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The box is shown but not yet placed when the anchor is unknown; the
    /// coordinator calls this again once Accessibility answers.
    func show(anchoredTo anchor: BoxAnchor) {
        self.anchor = anchor
        if !isVisible { shownAt = Date() }
        host.layoutSubtreeIfNeeded()
        var size = CGSize(width: model.width, height: host.fittingSize.height)
        // A hosting view that has not laid out yet reports nothing; never show a zero box.
        if size.height < 40 { size.height = 140 }
        place(size: size)
        remeasureSoon()
        // No fade: a window animation that fails to run would leave the box
        // on screen at alpha 0, which is indistinguishable from absent.
        alphaValue = 1
        orderFrontRegardless()
        makeKey()
        if let inputField { makeFirstResponder(inputField) }
        installMonitors()
    }

    /// "visible yes · key yes · frame 412,618 360×184 · screen 1440×900 · state empty": what the box did.
    var diagnosticLine: String {
        let f = frame
        let screen = NSScreen.screens.first { $0.frame.intersects(f) }?.frame.size ?? .zero
        return "visible \(isVisible ? "yes" : "no") · key \(isKeyWindow ? "yes" : "no") · alpha \(alphaValue) · frame \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)) · screen \(Int(screen.width))×\(Int(screen.height)) · state \(model.state)"
    }

    func dismiss() {
        removeMonitors()
        anchor = nil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard isVisible, !reduceMotion else {
            orderOut(nil)
            return
        }
        orderOut(nil)
    }

    /// The card changes width (360 → 480 when an answer arrives) and height
    /// as it streams; the window must follow, or the wider card is centred
    /// in the old frame and clipped on both sides (the first real answer
    /// was). Observation fires once per change, so it re-registers.
    private func observeModel() {
        withObservationTracking {
            _ = model.state
            _ = model.answer
            _ = model.outcome
            _ = model.proposal
            _ = model.failure
            _ = model.options
            _ = model.chips
            _ = model.selection
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refit()
                self?.observeModel()
            }
        }
    }

    /// Size the window to the card, in place. The width is a function of
    /// the state (360, or 480 with an answer) and is applied at once; the
    /// height is measured now and again a frame later, because observation
    /// fires before SwiftUI has rendered the change (1.0.5 measured the old
    /// layout and kept the old width, so the wider card was clipped).
    func refit() {
        guard isVisible else { return }
        host.layoutSubtreeIfNeeded()
        var height = host.fittingSize.height
        if height < 40 { height = frame.height }
        let size = CGSize(width: model.width, height: height)
        if abs(size.width - frame.width) > 0.5 || abs(size.height - frame.height) > 0.5 {
            place(size: size)
        }
        remeasureSoon()
    }

    /// SwiftUI's own word on the card's size, after layout: the only
    /// measurement that was right on the owner's Mac (fittingSize lagged
    /// and clipped the action row).
    private func cardDidLayout(_ size: CGSize) {
        guard isVisible, size.width >= 100, size.height >= 40 else { return }
        if abs(size.width - frame.width) > 0.5 || abs(size.height - frame.height) > 0.5 {
            place(size: size)
        }
    }

    private var remeasure: DispatchWorkItem?

    private func remeasureSoon() {
        remeasure?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.host.layoutSubtreeIfNeeded()
                let height = self.host.fittingSize.height
                guard height >= 40, abs(height - self.frame.height) > 0.5 || abs(self.model.width - self.frame.width) > 0.5 else { return }
                self.place(size: CGSize(width: self.model.width, height: height))
            }
        }
        remeasure = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    /// Re-anchor after the hosting view changed the window's size, so a
    /// box below its selection grows downward and never covers it.
    private func follow() {
        guard isVisible else { return }
        place(size: frame.size)
        invalidateShadow()
    }

    private func place(size: CGSize) {
        guard let anchor else { return }
        let point = CGPoint(x: anchor.rect.midX, y: anchor.rect.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let target = BoxPlacement.frame(size: size, anchor: anchor, screenVisible: visible)
        if frame != target { setFrame(target, display: true) }
    }

    // MARK: Keys the field does not see

    /// ⌘1–⌘8 chips, ⌘↩ the primary action, ⌘C the answer when nothing in
    /// the field is selected.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            if let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }), (1...8).contains(digit) {
                model.chip(number: digit)
                return true
            }
            if event.keyCode == 36 || event.keyCode == 76 { // Return, Enter
                model.primary()
                return true
            }
            if event.charactersIgnoringModifiers == "c", model.state == .done,
               let editor = fieldEditor(false, for: inputField) as? NSTextView, editor.selectedRange().length == 0 {
                model.onAction(.copy)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        model.escape()
    }

    // MARK: Outside

    private func installMonitors() {
        guard mouseMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            if let self, event.window !== self { MainActor.assumeIsolated { self.clickedOutside() } }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func removeMonitors() {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors = []
    }

    private func clickedOutside() {
        guard isVisible else { return }
        model.onClose()
    }
}
