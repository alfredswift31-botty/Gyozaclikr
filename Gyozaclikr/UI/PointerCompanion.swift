import AppKit
import SwiftUI

/// A small olive gyoza that floats beside the pointer while the app runs:
/// the owner's sign that Gyozaclikr is open and listening. Click-through,
/// never key, on every Space, hidden while the box is up. It follows the
/// pointer through a global mouse-moved monitor (no permission needed) at a
/// fixed offset below-right, and bobs gently unless Reduce Motion is on.
final class PointerCompanion {
    /// Window size: the glyph plus room for its glow.
    static let size: CGFloat = 30
    /// Where the glyph sits relative to the pointer's tip.
    static let offset = CGPoint(x: 14, y: -26)

    private var window: NSPanel?
    private var monitor: Any?
    private var hiddenForBox = false
    private(set) var isEnabled = false

    /// Start following the pointer, or stop. Idempotent.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            if window == nil { window = Self.makeWindow() }
            if monitor == nil {
                monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
                    MainActor.assumeIsolated { self?.follow() }
                }
            }
            follow()
            if !hiddenForBox { window?.orderFrontRegardless() }
        } else {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            window?.orderOut(nil)
        }
    }

    /// The box is up: step aside. Back when it closes.
    func boxShown() {
        hiddenForBox = true
        window?.orderOut(nil)
    }

    func boxHidden() {
        hiddenForBox = false
        guard isEnabled else { return }
        follow()
        window?.orderFrontRegardless()
    }

    private func follow() {
        guard let window, isEnabled else { return }
        let pointer = NSEvent.mouseLocation
        window.setFrameOrigin(Self.origin(forPointer: pointer))
    }

    /// Pure: the window's bottom-left for a pointer tip, in AppKit coordinates.
    nonisolated static func origin(forPointer pointer: CGPoint) -> CGPoint {
        CGPoint(x: pointer.x + offset.x, y: pointer.y + offset.y - size / 2)
    }

    private static func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isFloatingPanel = true
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

/// The hologram: an olive gyoza over a soft glow of the same colour, at
/// 85 % opacity. Static; the window's layer does the bobbing.
struct PointerCompanionView: View {

    static let olive = Color(red: 0.45, green: 0.56, blue: 0.16)
    static let oliveLight = Color(red: 0.62, green: 0.74, blue: 0.30)

    var body: some View {
        ZStack {
            GyozaGlyph(grid: 18, stroke: 1.6, pleat: 1.1)
                .fill(Self.olive.opacity(0.35))
                .blur(radius: 3)
            GyozaGlyph(grid: 18, stroke: 1.6, pleat: 1.1)
                .fill(LinearGradient(colors: [Self.oliveLight, Self.olive], startPoint: .top, endPoint: .bottom))
        }
        .frame(width: 20, height: 20)
        .padding(5)
        .opacity(0.85)
        .accessibilityHidden(true)
    }
}
