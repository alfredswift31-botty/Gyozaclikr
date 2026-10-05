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
        host.rootView = AnyView(BoxView(model: model, registerInput: { [weak self] field in self?.inputField = field }))
        host.sizingOptions = [.preferredContentSize]
        contentView = host
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        })
        // Switching apps or clicking elsewhere closes the box; observed once, acted on only while visible.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                // The source app re-activating when the panel takes key is not a switch away.
                if let app, app.processIdentifier == self.model.selection.sourceApp?.pid { return }
                self.model.onClose()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.model.onClose()
            }
        })
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The box is shown but not yet placed when the anchor is unknown; the
    /// coordinator calls this again once Accessibility answers.
    func show(anchoredTo anchor: BoxAnchor) {
        self.anchor = anchor
        host.layoutSubtreeIfNeeded()
        place(size: host.fittingSize)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !isVisible {
            alphaValue = reduceMotion ? 1 : 0
        }
        makeKeyAndOrderFront(nil)
        if !reduceMotion, alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Box.fade
                animator().alphaValue = 1
            }
        }
        if let inputField { makeFirstResponder(inputField) }
        installMonitors()
    }

    func dismiss() {
        removeMonitors()
        anchor = nil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard isVisible, !reduceMotion else {
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Theme.Box.fade
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.anchor == nil else { return }
                self.orderOut(nil)
                self.alphaValue = 1
            }
        })
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
