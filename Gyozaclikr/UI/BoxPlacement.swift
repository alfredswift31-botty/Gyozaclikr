import CoreGraphics
import Foundation

/// Where the box is anchored. Rectangles and points are in AppKit screen
/// coordinates (origin at the bottom-left of the primary display).
nonisolated enum BoxAnchor: Hashable, Sendable {
    /// The selection's bounds from Accessibility: the box sits below its last line.
    case selection(CGRect)
    /// A captured region: the box sits below its bottom-left.
    case region(CGRect)
    /// Nothing better: the box sits below-right of the pointer.
    case pointer(CGPoint)

    /// The rectangle the box must never cover (a point for the pointer).
    var rect: CGRect {
        switch self {
        case .selection(let r), .region(let r): r
        case .pointer(let p): CGRect(origin: p, size: .zero)
        }
    }
}

/// The pure arithmetic behind `BoxPanel.show`: docs/DESIGN.md "Anchor".
/// Below the anchor by 8 pt (12 pt below-right of the pointer), flipped
/// above when there is no room, shifted to stay 16 pt inside the visible
/// screen, never covering the anchor. Tested in UITests.
nonisolated enum BoxPlacement {
    struct Result: Hashable, Sendable {
        var frame: CGRect
        /// True when the box was flipped above its anchor.
        var above: Bool
    }

    /// The distances, mirrored from `Theme.Box` so this stays callable off
    /// the main actor; a test keeps them equal.
    static let anchorGap: CGFloat = 8
    static let pointerOffset: CGFloat = 12
    static let screenInset: CGFloat = 16

    static func frame(size: CGSize, anchor: BoxAnchor, screenVisible: CGRect) -> CGRect {
        place(size: size, anchor: anchor, screenVisible: screenVisible).frame
    }

    static func place(size: CGSize, anchor: BoxAnchor, screenVisible screen: CGRect) -> Result {
        let inset = screenInset
        let gap: CGFloat
        let rect = anchor.rect
        var x: CGFloat
        switch anchor {
        case .selection, .region:
            gap = anchorGap
            x = rect.minX
        case .pointer:
            gap = pointerOffset
            x = rect.minX + pointerOffset
        }
        let belowY = rect.minY - gap - size.height
        let aboveY = rect.maxY + gap
        let lowest = screen.minY + inset
        let highest = screen.maxY - inset - size.height

        var above = false
        var y = belowY
        if belowY < lowest {
            // No room below: flip, unless above is worse.
            let roomAbove = screen.maxY - inset - aboveY
            let roomBelow = belowY - lowest
            if roomAbove >= 0 || roomAbove > roomBelow {
                above = true
                y = aboveY
            }
        }
        // Stay inside the screen: left and right, then top and bottom. The
        // vertical clamp only bites on a screen too short for the box.
        x = min(max(x, screen.minX + inset), max(screen.minX + inset, screen.maxX - inset - size.width))
        y = min(max(y, lowest), max(lowest, highest))
        return Result(frame: CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), above: above)
    }
}
