import AppKit
import ApplicationServices
import SwiftUI

/// A small gyoza that floats beside the pointer while the app runs: the
/// owner's sign that Gyozaclikr is open and listening. The owner's own
/// drawing (1.1.5), cut out of its background, replaced the olive hologram.
/// Click-through, never key, on every Space, hidden while the box is up.
/// It follows the pointer through a global mouse-moved monitor at a fixed
/// offset below-right, and bobs gently unless Reduce Motion is on.
///
/// It behaves like the cursor it sits beside (1.1.6): it hides when the
/// owner types, as macOS hides the pointer, and comes back on the first
/// mouse move; and it floats above menus, because the pointer does.
final class PointerCompanion {
    /// Window size: the 32 × 28 pt drawing plus room for the bob.
    static let size = CGSize(width: 38, height: 34)
    /// Where the glyph sits relative to the pointer's tip.
    static let offset = CGPoint(x: 14, y: -26)
    /// Above context and pop-up menus (pop-up menu level is 101) and the
    /// status bar, below the cursor: the assistive-technology layer that
    /// pointer highlighters use. At `.statusBar` (1.0.3 to 1.1.5) every
    /// open menu covered the gyoza while the pointer sat on top of it.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))

    private var window: NSPanel?
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    /// Whether the key monitor was installed while the app held Accessibility.
    /// macOS delivers other apps' keys only to a monitor installed while
    /// trusted, and after every update the owner launches first and re-grants
    /// second, so 1.1.6's monitor never heard a key.
    private var keyMonitorTrusted = false
    private var trustTimer: Timer?
    private var trustObserver: NSObjectProtocol?
    private var hiddenForBox = false
    private var hiddenForTyping = false
    private(set) var isEnabled = false

    /// Start following the pointer, or stop. Idempotent.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            if window == nil { window = Self.makeWindow() }
            if mouseMonitor == nil {
                mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] _ in
                    MainActor.assumeIsolated { self?.mouseMoved() }
                }
            }
            armKeyMonitor()
            watchTrust()
            hiddenForTyping = false
            refresh()
        } else {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            mouseMonitor = nil
            keyMonitor = nil
            keyMonitorTrusted = false
            trustTimer?.invalidate()
            trustTimer = nil
            if let trustObserver { DistributedNotificationCenter.default().removeObserver(trustObserver) }
            trustObserver = nil
            window?.orderOut(nil)
        }
    }

    // MARK: Typing, and the Accessibility grant it depends on

    /// (Re)install the key monitor, noting whether the app is trusted now.
    private func armKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let hides = Self.hidesWhileTyping(event.modifierFlags)
            MainActor.assumeIsolated { if hides { self?.typed() } }
        }
        keyMonitorTrusted = AXIsProcessTrusted()
        if keyMonitorTrusted {
            trustTimer?.invalidate()
            trustTimer = nil
        } else if trustTimer == nil {
            // Until the grant arrives, look every two seconds; then re-arm once and stop.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkTrust() }
            }
        }
    }

    /// The system announces Accessibility changes; the grant itself lands a
    /// moment later, so look again after half a second.
    private func watchTrust() {
        guard trustObserver == nil else { return }
        trustObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.checkTrust() }
            }
        }
    }

    private func checkTrust() {
        guard isEnabled else { return }
        let trusted = AXIsProcessTrusted()
        if Self.needsRearm(monitorTrusted: keyMonitorTrusted, trustedNow: trusted) {
            armKeyMonitor()
        } else if !trusted {
            keyMonitorTrusted = false
            if trustTimer == nil { armKeyMonitor() }
        }
    }

    /// Pure: a monitor installed without the grant must be installed again once it arrives.
    nonisolated static func needsRearm(monitorTrusted: Bool, trustedNow: Bool) -> Bool {
        trustedNow && !monitorTrusted
    }

    /// "gyoza level 1500 · shown · typing armed": what the companion is doing, for the Engines pane.
    var diagnosticLine: String {
        let level = window.map { "\($0.level.rawValue)" } ?? "none"
        let state = !isEnabled ? "off" : hiddenForBox ? "hidden for the box" : hiddenForTyping ? "hidden for typing" : "shown"
        let typing = keyMonitorTrusted ? "typing armed" : "typing waits for Accessibility"
        return "gyoza level \(level) · \(state) · \(typing)"
    }

    /// The box is up: step aside. Back when it closes.
    func boxShown() {
        hiddenForBox = true
        refresh()
    }

    func boxHidden() {
        hiddenForBox = false
        hiddenForTyping = false
        refresh()
    }

    /// A key went down in another app: hide until the mouse moves, as the
    /// cursor does. Only on the change, so a burst of typing costs nothing.
    private func typed() {
        guard isEnabled, !hiddenForTyping else { return }
        hiddenForTyping = true
        refresh()
    }

    private func mouseMoved() {
        follow()
        guard hiddenForTyping else { return }
        hiddenForTyping = false
        refresh()
    }

    /// Shown exactly when enabled, the box is closed and the owner is not typing.
    private func refresh() {
        guard let window else { return }
        if Self.isVisible(enabled: isEnabled, hiddenForBox: hiddenForBox, hiddenForTyping: hiddenForTyping) {
            follow()
            if window.level != Self.level { window.level = Self.level }
            window.orderFrontRegardless()
        } else {
            window.orderOut(nil)
        }
    }

    /// Pure: whether the gyoza shows.
    nonisolated static func isVisible(enabled: Bool, hiddenForBox: Bool, hiddenForTyping: Bool) -> Bool {
        enabled && !hiddenForBox && !hiddenForTyping
    }

    /// Pure: whether a key press hides the gyoza. Typing does, Shift and
    /// Option included (capitals, accents); a ⌘ or ⌃ shortcut does not,
    /// since macOS leaves the cursor up for shortcuts too.
    nonisolated static func hidesWhileTyping(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .control]).isEmpty
    }

    private func follow() {
        guard let window, isEnabled else { return }
        let pointer = NSEvent.mouseLocation
        window.setFrameOrigin(Self.origin(forPointer: pointer))
    }

    /// Pure: the window's bottom-left for a pointer tip, in AppKit coordinates.
    nonisolated static func origin(forPointer pointer: CGPoint) -> CGPoint {
        CGPoint(x: pointer.x + offset.x, y: pointer.y + offset.y - size.height / 2)
    }

    /// Internal so a test can check the real window's level, not just the constant.
    static func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Not `isFloatingPanel = true`: setting it resets the level to
        // `.floating` (3), below every menu, which is where the gyoza sat
        // from 1.0.3 to 1.1.6 whatever level was set before it.
        panel.level = level
        let host = NSHostingView(rootView: PointerCompanionView())
        host.wantsLayer = true
        panel.contentView = host
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = host.layer {
            // A layer animation: the render server bobs the glyph, the app
            // never redraws (a SwiftUI repeatForever would, every frame).
            let bob = CABasicAnimation(keyPath: "transform.translation.y")
            bob.fromValue = 0
            bob.toValue = 2
            bob.duration = 2
            bob.autoreverses = true
            bob.repeatCount = .infinity
            bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(bob, forKey: "bob")
        }
        return panel
    }
}

/// The owner's gyoza drawing (Assets › PointerGyoza, 1x and 2x), alone:
/// no glow, full opacity. Static; the window's layer does the bobbing.
struct PointerCompanionView: View {
    static let drawing = CGSize(width: 32, height: 28)

    var body: some View {
        Image("PointerGyoza")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: Self.drawing.width, height: Self.drawing.height)
            .frame(width: PointerCompanion.size.width, height: PointerCompanion.size.height)
            .accessibilityHidden(true)
    }
}
