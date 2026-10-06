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
    /// True while the panel sets its own frame, so a move is not mistaken for the user's.
    private var placing = false
    /// The user dragged the box: it keeps its top-left corner from then on.
    private var userMoved = false
    private var mouseMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    init(model: BoxModel) {
        self.model = model
        let box = BoxView(model: model, registerInput: nil)
        host = NSHostingView(rootView: AnyView(box))
        super.init(contentRect: NSRect(x: 0, y: 0, width: Theme.Box.width, height: 120),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView, .resizable],
                   backing: .buffered, defer: false)
        // The card draws its own material, radius and hairline; the window
        // is clear and carries only its shadow.
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        // The card's own drag gesture moves the panel (`drag(by:ended:)`);
        // AppKit's movable background never fired through the hosting view.
        isMovableByWindowBackground = false
        minSize = BoxModel.minSize
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        host.rootView = AnyView(BoxView(model: model,
                                        registerInput: { [weak self] field in self?.inputField = field },
                                        onSize: { [weak self] size in self?.cardDidLayout(size) },
                                        onDrag: { [weak self] delta, ended in self?.drag(by: delta, ended: ended) },
                                        onResize: { [weak self] delta, ended in self?.resize(by: delta, ended: ended) }))
        // The panel sizes itself (refit): the hosting view's own sizing fought it.
        host.sizingOptions = []
        contentView = host
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // An edge drag (AppKit's live resize) is the user's size from then on.
                if self.inLiveResize, !self.placing {
                    self.model.userSize = self.frame.size
                    self.userMoved = true
                }
                self.follow()
            }
        })
        observeModel()
        // The box stays until closed (the × or Esc): switching apps or clicking
        // elsewhere leaves it, so an answer can be read beside other work.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.placing else { return }
                self.userMoved = true
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
        // A fresh summon goes to the new selection, wherever the last box was dragged.
        userMoved = false
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
            _ = model.userSize
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
        // The user's size wins over the content's; the card fills it.
        let size = model.userSize ?? size
        let target: CGRect
        if userMoved {
            // Where the user put it: grow downward from the same top-left corner.
            target = CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        } else {
            guard let anchor else { return }
            let point = CGPoint(x: anchor.rect.midX, y: anchor.rect.midY)
            let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
            let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            target = BoxPlacement.frame(size: size, anchor: anchor, screenVisible: visible)
        }
        guard frame != target else { return }
        placing = true
        setFrame(target, display: true)
        placing = false
    }

    // MARK: Dragging

    /// The frame's origin when the current drag began.
    private var dragOrigin: CGPoint?

    /// Move by the pointer's displacement since the drag began. The move
    /// posts `didMove`, which marks the box as the user's to keep in place.
    func drag(by delta: CGSize, ended: Bool) {
        if ended { dragOrigin = nil; return }
        let origin = dragOrigin ?? frame.origin
        dragOrigin = origin
        setFrameOrigin(CGPoint(x: origin.x + delta.width, y: origin.y + delta.height))
    }

    /// The frame when the current corner drag began.
    private var resizeOrigin: CGRect?

    /// Resize from the bottom-right grip: the right edge follows the
    /// pointer's x, the bottom edge its y, the top-left corner stays.
    func resize(by delta: CGSize, ended: Bool) {
        if ended { resizeOrigin = nil; return }
        let start = resizeOrigin ?? frame
        resizeOrigin = start
        let bounds = (screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let target = Self.resized(from: start, by: delta, within: bounds)
        guard target != frame else { return }
        model.userSize = target.size
        userMoved = true
        placing = true
        setFrame(target, display: true)
        placing = false
    }

    /// Pure: the frame after a corner drag, clamped to the minimum size and
    /// to the screen. Dragging down (negative y in AppKit) makes it taller.
    nonisolated static func resized(from start: CGRect, by delta: CGSize, within bounds: CGRect) -> CGRect {
        let maxWidth = max(BoxModel.minSize.width, bounds.maxX - start.minX)
        let maxHeight = max(BoxModel.minSize.height, start.maxY - bounds.minY)
        let width = min(max(start.width + delta.width, BoxModel.minSize.width), maxWidth)
        let height = min(max(start.height - delta.height, BoxModel.minSize.height), maxHeight)
        return CGRect(x: start.minX, y: start.maxY - height, width: width, height: height)
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

    /// Nothing outside the box closes it any more; the × and Esc do.
    private func installMonitors() {}
    private func removeMonitors() {}
}
