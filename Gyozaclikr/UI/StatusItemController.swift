import AppKit
import SwiftUI

/// What the menu shows, as data: the controller builds the `NSMenu` from
/// it and the snapshot test renders `StatusMenuView` from the same items,
/// since an NSMenu cannot be drawn off screen.
nonisolated struct StatusMenuModel: Hashable, Sendable {
    /// "⌃Space", as the Capture module prints the registered shortcut.
    var shortcutText: String = "⌃Space"
    var diagnostics = EngineDiagnostics()
    var permissions: [Permission: PermissionState] = [:]
    var hasLastAnswer = false

    /// The permissions the menu lists (docs/DESIGN.md "Menu bar").
    static let listed: [Permission] = [.accessibility, .screenRecording, .reminders, .calendar, .automationNotes]

    var missingPermission: Bool {
        Self.listed.contains { permissions[$0] != .granted }
    }

    struct Item: Hashable, Identifiable, Sendable {
        enum Kind: Hashable, Sendable { case open, lastAnswer, history, engines, permissions, settings, quit, separator, status, grant(Permission) }
        var id: String
        var kind: Kind
        var title: String
        var shortcut: String?
        var enabled = true
        var children: [Item] = []
        /// A ● before the title (a granted permission).
        var dotted = false
    }

    var items: [Item] {
        [
            Item(id: "open", kind: .open, title: "Open Gyozaclikr", shortcut: shortcutText),
            Item(id: "last", kind: .lastAnswer, title: "Last answer…", enabled: hasLastAnswer),
            Item(id: "history", kind: .history, title: "History…"),
            Item(id: "sep1", kind: .separator, title: ""),
            Item(id: "engines", kind: .engines, title: "Engines", children: engineLines.enumerated().map {
                Item(id: "engine\($0.offset)", kind: .status, title: $0.element, enabled: false)
            }),
            Item(id: "permissions", kind: .permissions, title: "Permissions", children: Self.listed.map { permission in
                let granted = permissions[permission] == .granted
                return Item(id: "perm-\(permission.rawValue)", kind: granted ? .status : .grant(permission),
                            title: granted ? permission.title : "\(permission.title) · Grant…", enabled: !granted, dotted: granted)
            }),
            Item(id: "sep2", kind: .separator, title: ""),
            Item(id: "settings", kind: .settings, title: "Settings…", shortcut: "⌘,"),
            Item(id: "quit", kind: .quit, title: "Quit Gyozaclikr", shortcut: "⌘Q"),
        ]
    }

    /// Three disabled lines: Apple Intelligence's state, Ollama reachable or off, Claude keyed or not.
    var engineLines: [String] {
        let apple: String = switch diagnostics.apple {
        case .ready: "Apple Intelligence · ready"
        case .unavailable(let why): "Apple Intelligence · \(why)"
        }
        let ollama: String = switch diagnostics.ollama {
        case .ready: "Ollama · reachable" + (diagnostics.ollamaVisionModel.map { " · \($0)" } ?? "")
        case .unavailable: "Ollama · off"
        }
        let claude: String = switch diagnostics.claude {
        case .ready: "Claude · CLI installed"
        case .unavailable: "Claude · needs the claude CLI"
        }
        return [apple, ollama, claude]
    }
}

/// The menu-bar item: a template gyoza (GyozaVitals' drawing), a dot only
/// when a permission is missing, the menu above, and one nudge when a
/// result lands (the single animation docs/DESIGN.md allows).
final class StatusItemController: NSObject, NSMenuDelegate {
    var onOpen: () -> Void = {}
    var onLastAnswer: () -> Void = {}
    var onHistory: () -> Void = {}
    var onGrant: (Permission) -> Void = { _ in }
    var onSettings: () -> Void = {}
    var onQuit: () -> Void = { NSApplication.shared.terminate(nil) }

    var menuModel = StatusMenuModel() {
        didSet { if menuModel != oldValue { refresh() } }
    }

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.image = Self.glyph(dot: false)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.setAccessibilityLabel("Gyozaclikr")
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refresh()
    }

    /// The glyph bounces once; nothing happens under Reduce Motion.
    func nudge() {
        guard let button = statusItem.button, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bounce.values = [0, 3, -1, 0]
        bounce.keyTimes = [0, 0.35, 0.7, 1]
        bounce.duration = 0.32
        bounce.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(bounce, forKey: "nudge")
    }

    // MARK: Menu

    private func refresh() {
        statusItem.button?.image = Self.glyph(dot: menuModel.missingPermission)
        statusItem.button?.setAccessibilityLabel(menuModel.missingPermission ? "Gyozaclikr, a permission is missing" : "Gyozaclikr")
        menu.removeAllItems()
        for item in menuModel.items { menu.addItem(makeItem(item)) }
    }

    private func makeItem(_ item: StatusMenuModel.Item) -> NSMenuItem {
        if item.kind == .separator { return .separator() }
        let menuItem = NSMenuItem(title: item.dotted ? "● \(item.title)" : item.title, action: #selector(activate(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.isEnabled = item.enabled
        menuItem.representedObject = item.id
        switch item.kind {
        case .open:
            // The global shortcut is drawn as text: it is not a menu key equivalent.
            menuItem.attributedTitle = Self.titleWithShortcut(item.title, shortcut: item.shortcut ?? "")
        case .settings:
            menuItem.keyEquivalent = ","
        case .quit:
            menuItem.keyEquivalent = "q"
        default:
            break
        }
        if !item.children.isEmpty {
            let submenu = NSMenu(title: item.title)
            submenu.autoenablesItems = false
            for child in item.children { submenu.addItem(makeItem(child)) }
            menuItem.submenu = submenu
            menuItem.isEnabled = true
        }
        return menuItem
    }

    @objc private func activate(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = menuModel.items.flatMap({ [$0] + $0.children }).first(where: { $0.id == id }) else { return }
        switch item.kind {
        case .open: onOpen()
        case .lastAnswer: onLastAnswer()
        case .history: onHistory()
        case .grant(let permission): onGrant(permission)
        case .settings: onSettings()
        case .quit: onQuit()
        case .engines, .permissions, .separator, .status: break
        }
    }

    private static func titleWithShortcut(_ title: String, shortcut: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        if !shortcut.isEmpty {
            result.append(NSAttributedString(string: "    \(shortcut)", attributes: [
                .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return result
    }

    // MARK: Glyph

    /// The pleat stroke of the GyozaVitals drawing.
    static let pleatStroke: CGFloat = 1

    /// The gyoza at 2x, alpha only, so the system tints it; with a 4-pt dot
    /// at the bottom right when a permission is missing.
    static func glyph(dot: Bool) -> NSImage {
        let size = Theme.StatusItem.glyphSize
        let shape = GyozaGlyph(grid: size, stroke: Theme.StatusItem.stroke, pleat: pleatStroke)
        let content = ZStack(alignment: .bottomTrailing) {
            shape.fill(Color.black).frame(width: size, height: size)
            if dot {
                Circle().fill(Color.black).frame(width: 4, height: 4).offset(x: 1, y: 1)
            }
        }
        .frame(width: size + 2, height: size + 2)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let image = renderer.nsImage {
            image.isTemplate = true
            image.size = NSSize(width: size + 2, height: size + 2)
            return image
        }
        let fallback = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Gyozaclikr") ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }
}

/// A little gyoza: a plump half-moon with rounded corners, three short
/// pleat marks crimped along its arc, resting on a short plate. The
/// GyozaVitals drawing, on an 18 pt grid, 1.5 pt stroke, round caps.
nonisolated struct GyozaGlyph: Shape {
    let grid: CGFloat
    let stroke: CGFloat
    let pleat: CGFloat

    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / grid
        let center = CGPoint(x: rect.midX, y: rect.minY + 11 * unit)
        let radius = 7 * unit
        let corner = 2.25 * unit
        let plateY = rect.minY + 15.25 * unit

        func onArc(_ degrees: Double, _ r: CGFloat) -> CGPoint {
            let angle = degrees * .pi / 180
            return CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
        }

        var body = Path()
        body.move(to: CGPoint(x: center.x, y: center.y))
        body.addArc(tangent1End: CGPoint(x: center.x + radius, y: center.y),
                    tangent2End: CGPoint(x: center.x + radius, y: center.y - corner), radius: corner)
        let steps = 40
        let from = -18.0, to = -162.0
        for step in 0...steps {
            body.addLine(to: onArc(from + (to - from) * Double(step) / Double(steps), radius))
        }
        body.addArc(tangent1End: CGPoint(x: center.x - radius, y: center.y),
                    tangent2End: CGPoint(x: center.x, y: center.y), radius: corner)
        body.closeSubpath()
        body.move(to: CGPoint(x: center.x - 4.5 * unit, y: plateY))
        body.addLine(to: CGPoint(x: center.x + 4.5 * unit, y: plateY))
        var result = body.strokedPath(StrokeStyle(lineWidth: stroke * unit, lineCap: .round, lineJoin: .round))

        var pleats = Path()
        for degrees in [-122.0, -90, -58] {
            pleats.move(to: onArc(degrees, radius - 2.5 * unit))
            pleats.addLine(to: onArc(degrees, radius + 0.25 * unit))
        }
        result.addPath(pleats.strokedPath(StrokeStyle(lineWidth: pleat * unit, lineCap: .round)))
        return result
    }
}

/// The menu as a list, for the snapshot: the same items the NSMenu gets.
struct StatusMenuView: View {
    let model: StatusMenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image(nsImage: StatusItemController.glyph(dot: model.missingPermission))
                    .renderingMode(.template)
                    .foregroundStyle(Theme.ink)
                Text("menu bar").labelStyle()
            }
            .padding(.bottom, Theme.Space.s)
            ForEach(model.items) { item in
                row(item, indent: 0)
                ForEach(item.children) { child in row(child, indent: 1) }
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.container))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.container).strokeBorder(Theme.hairline))
    }

    @ViewBuilder
    private func row(_ item: StatusMenuModel.Item, indent: Int) -> some View {
        if item.kind == .separator {
            Hairline().padding(.vertical, Theme.Space.xs)
        } else {
            HStack(spacing: Theme.Space.s) {
                if item.dotted { Text("●").font(Font.system(size: 8)).foregroundStyle(Theme.ink) }
                Text(item.title)
                    .font(Theme.Typeface.meta)
                    .foregroundStyle(item.enabled ? Theme.ink : Theme.inkTertiary)
                Spacer()
                if let shortcut = item.shortcut {
                    Text(shortcut).font(Theme.Typeface.mono).foregroundStyle(Theme.inkTertiary)
                }
                if !item.children.isEmpty {
                    Text("▸").font(Theme.Typeface.meta).foregroundStyle(Theme.inkTertiary)
                }
            }
            .padding(.leading, CGFloat(indent) * Theme.Space.l)
            .frame(height: 22)
        }
    }
}
