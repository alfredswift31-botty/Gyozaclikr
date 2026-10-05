import AppKit
import SwiftUI

/// The box's input: an `NSTextField` that wraps up to six lines, so the
/// panel can make it first responder without activating the app (SwiftUI
/// focus does not land in a non-activating panel). Keys per docs/DESIGN.md:
/// Enter submits, ⇧Enter breaks the line, Esc cancels or closes, ↑ recalls,
/// Tab accepts the suggested chip. ⌘-shortcuts are the panel's.
struct BoxInput: NSViewRepresentable {
    let model: BoxModel
    /// Hands the field to the panel for `makeFirstResponder`.
    var register: ((InputField) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> InputField {
        let field = InputField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = BoxFont.nsBody
        field.textColor = .labelColor
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.maximumNumberOfLines = 6
        field.allowsEditingTextAttributes = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.model = model
        register?(field)
        return field
    }

    func updateNSView(_ field: InputField, context: Context) {
        if field.stringValue != model.input { field.stringValue = model.input }
        let placeholder = model.placeholder
        if context.coordinator.placeholder != placeholder {
            context.coordinator.placeholder = placeholder
            field.placeholderAttributedString = Self.placeholder(placeholder, word: model.selection.kind == .word ? model.selection.word : nil)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: InputField, context: Context) -> CGSize? {
        let width = proposal.width ?? Theme.Box.width - 2 * Theme.Box.padding
        field.preferredMaxLayoutWidth = width
        let height = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 20
        return CGSize(width: width, height: max(20, ceil(height)))
    }

    /// "Define *word*…": the word in italics, the rest in the placeholder grey.
    static func placeholder(_ text: String, word: String?) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: BoxFont.nsBody, .foregroundColor: NSColor.placeholderTextColor,
        ])
        if let word, let range = text.range(of: word) {
            let italic = NSFontManager.shared.convert(BoxFont.nsBody, toHaveTrait: .italicFontMask)
            result.addAttribute(.font, value: italic, range: NSRange(range, in: text))
        }
        return result
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: BoxModel
        var placeholder = ""
        init(model: BoxModel) { self.model = model }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.inputChanged(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    model.inputChanged(control.stringValue)
                } else {
                    model.submit()
                }
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                return false
            case #selector(NSResponder.cancelOperation(_:)):
                model.escape()
                return true
            case #selector(NSResponder.moveUp(_:)):
                // ↑ recalls only from the first line; inside a longer text it moves the caret.
                let caret = textView.selectedRange().location
                let firstLineEnd = (textView.string as NSString).range(of: "\n").location
                if caret <= (firstLineEnd == NSNotFound ? Int.max : firstLineEnd) {
                    model.recall()
                    return true
                }
                return false
            case #selector(NSResponder.insertTab(_:)):
                return model.acceptSuggestion()
            default:
                return false
            }
        }
    }
}

/// The field itself: wraps, reports its ideal height, and lets the panel
/// find it. Nothing more; keys are handled by the delegate.
final class InputField: NSTextField {
    weak var model: BoxModel?

    override var intrinsicContentSize: NSSize {
        let width = preferredMaxLayoutWidth > 0 ? preferredMaxLayoutWidth : bounds.width
        guard width > 0, let cell else { return super.intrinsicContentSize }
        let height = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
        return NSSize(width: NSView.noIntrinsicMetric, height: max(20, ceil(height)))
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        invalidateIntrinsicContentSize()
    }
}

/// The box's type (docs/DESIGN.md "Form"): system 13 pt, SF Mono 11 pt for figures.
enum BoxFont {
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let mono = Font.system(size: 11, design: .monospaced)
    static let small = Font.system(size: 11)
    static let nsBody = NSFont.systemFont(ofSize: 13)
}
