import AppKit
import SwiftUI

/// Gyozaclikr's design system (shared with GyozaYap and GyozaVitals): Swiss / International Typographic style.
/// Monochrome, one typeface family (San Francisco) doing all the work through
/// size and weight, small bold uppercase labels over plain values, hairlines
/// instead of boxes, and one colour, red, reserved for "live". Every screen
/// builds from these tokens; see docs/DESIGN.md for the rules.
enum Theme {
    // MARK: Colour

    /// A colour with a light and a dark value.
    private static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map {
                $0 == .darkAqua || $0 == .vibrantDark
            } ?? false
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    /// The page: near-black in dark mode, off-white in light. Never pure.
    static let canvas = dynamic(light: 0xF5F5F4, dark: 0x111111)
    /// Fields and the few raised surfaces (text inputs, the notes pad).
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1A1A1A)
    /// Primary text and the primary button.
    static let ink = dynamic(light: 0x111111, dark: 0xF2F2F0)
    /// Secondary text: values under labels, descriptions. AA on canvas.
    static let inkSecondary = dynamic(light: 0x5C5C59, dark: 0xA3A3A0)
    /// Tertiary text: labels, timestamps, footnotes. Use at label sizes only.
    static let inkTertiary = dynamic(light: 0x7A7A76, dark: 0x7D7D7A)
    /// 1 pt dividers and outlines.
    static let hairline = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.12)
    /// Hover and selection washes.
    static let wash = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.07)
    /// Text on an `ink` fill (the primary button, a selected row).
    static let inkInverse = dynamic(light: 0xF5F5F4, dark: 0x111111)
    /// Destructive actions only; the box's live state uses the system accent.
    static let live = dynamic(light: 0xD7263D, dark: 0xFF4D5E)
    /// The user's accent: the suggested chip, the progress bar, the primary action.
    static let accent = Color.accentColor
    /// The icon's gradient. Allowed in exactly two places (docs/DESIGN.md):
    /// the top hairline of the box in the Ollama state, and the About pane.
    static let gradientStart = dynamic(light: 0x2F7BFF, dark: 0x4D8DFF)
    static let gradientEnd = dynamic(light: 0x8B5CF6, dark: 0xA78BFA)
    static var engineGradient: LinearGradient {
        LinearGradient(colors: [gradientStart, gradientEnd], startPoint: .leading, endPoint: .trailing)
    }

    // MARK: Type (San Francisco, one family)

    enum Typeface {
        /// One or two lowercase words carrying a screen: an empty state, the recording clock.
        static let display = Font.system(size: 56, weight: .medium)
        static let displayTracking: CGFloat = -2.2
        /// A meeting's title.
        static let title = Font.system(size: 28, weight: .semibold)
        static let titleTracking: CGFloat = -0.8
        /// A statement inside content (a TL;DR, an answer).
        static let lead = Font.system(size: 17, weight: .medium)
        static let leadTracking: CGFloat = -0.2
        /// Sidebar row titles, list item emphasis.
        static let heading = Font.system(size: 13.5, weight: .semibold)
        /// Running text.
        static let body = Font.system(size: 13.5)
        static let bodyLineSpacing: CGFloat = 4
        /// Values under a label, secondary lines.
        static let meta = Font.system(size: 12)
        /// Small bold uppercase labels: the poster's column headers.
        static let label = Font.system(size: 10.5, weight: .bold)
        static let labelTracking: CGFloat = 0.8
        /// Timestamps and durations: fixed width so columns line up.
        static let mono = Font.system(size: 11.5, design: .monospaced)
    }

    // MARK: Space, shape, motion

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
        /// Page margin of the detail and recording panes.
        static let page: CGFloat = 40
        /// Readable measure for running text.
        static let measure: CGFloat = 640
    }

    /// One radius scale, used everywhere: controls 5, containers 8. Nothing is a pill.
    enum Radius {
        static let control: CGFloat = 5
        static let container: CGFloat = 8
    }

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.18)
        static let calm = Animation.easeOut(duration: 0.3)
        static let pressedScale: CGFloat = 0.98
    }

    // MARK: Gyozaclikr additions (docs/DESIGN.md)

    /// The box: a card beside the selection.
    enum Box {
        static let width: CGFloat = 360
        /// One step wider while an answer streams.
        static let wideWidth: CGFloat = 480
        static let radius: CGFloat = 10
        static let padding: CGFloat = 12
        /// Gap between the selection and the box, and the pointer offset.
        static let anchorGap: CGFloat = 8
        static let pointerOffset: CGFloat = 12
        /// Minimum distance from the screen's edge.
        static let screenInset: CGFloat = 16
        static let chipHeight: CGFloat = 24
        static let chipSpacing: CGFloat = 6
        static let quoteLines = 2
        static let thumbnailHeight: CGFloat = 48
        /// Answers past this many lines offer "Open in new window".
        static let linesBeforeWindow = 12
        /// The accent bar under the status word.
        static let progressHeight: CGFloat = 2
        /// Visible this soon after the trigger.
        static let appearBudget: TimeInterval = 0.1
        static let fade: TimeInterval = 0.12
        /// Streamed text is coalesced in this window so the layout does not shake.
        static let coalesce: TimeInterval = 0.04
        /// Past this the status reads "Model is warming up…".
        static let warmUpAfter: TimeInterval = 2.5
    }

    enum Settings {
        static let width: CGFloat = 520
        static let height: CGFloat = 640
    }

    /// The status item: a template gyoza.
    enum StatusItem {
        static let glyphSize: CGFloat = 18
        static let stroke: CGFloat = 1.5
    }
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: - Text styles

extension View {
    /// Small bold uppercase label, as in the poster's column headers.
    func labelStyle() -> some View {
        self.font(Theme.Typeface.label)
            .tracking(Theme.Typeface.labelTracking)
            .textCase(.uppercase)
            .foregroundStyle(Theme.inkTertiary)
    }

    func titleStyle() -> some View {
        self.font(Theme.Typeface.title)
            .tracking(Theme.Typeface.titleTracking)
            .foregroundStyle(Theme.ink)
    }
}

// MARK: - Components

/// A label over a value: the poster's metadata columns (DATE / 12 Sep 2026).
struct MetaPair: View {
    let label: String
    let value: String
    var monospaced = false
    /// The value's colour when it must not be plain ink: `Theme.live` for a critical state.
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).labelStyle()
            Text(value)
                .font(monospaced ? Theme.Typeface.mono : Theme.Typeface.meta)
                .monospacedDigit()
                .foregroundStyle(tint ?? Theme.ink)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A 1 pt divider in the hairline colour.
struct Hairline: View {
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}

/// A section header: a label with a hairline running to the right edge.
struct SectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(title).labelStyle().fixedSize()
            Hairline()
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// A keyboard shortcut drawn as a key.
/// A small red dot that breathes while live and on screen; still when Reduce
/// Motion is on or when `animates` is false. A repeating animation keeps
/// SwiftUI rendering every frame even in a menu-bar window that has been
/// closed, so the owner turns it off with the window.
// MARK: - Fields

extension View {
    /// A text field or editor on the surface colour with a hairline edge.
    func fieldSurface() -> some View {
        self.padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.hairline))
    }
}
