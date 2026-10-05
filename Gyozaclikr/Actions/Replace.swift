import AppKit
import ApplicationServices

/// Writes an answer into the source app: set AXSelectedText on the focused
/// element and verify by re-reading, else paste with ⌘V and restore the
/// pasteboard (docs/research/system-integration.md §5). Needs the
/// Accessibility grant, which Capture owns.
enum Replace {
    static func perform(_ text: String, insertBelow: Bool, selection: Selection) async -> ActionOutcome {
        let app = selection.sourceApp?.name ?? "the app"
        let verb = insertBelow ? "Inserted" : "Replaced"
        let payload = insertBelow ? "\n" + text : text
        guard selection.isEditable else { return copyInstead(text, app: app) }
        if AXWriter.write(payload, insertBelow: insertBelow) { return .done(verb) }
        if await PasteWriter.paste(payload) { return .done(verb) }
        return copyInstead(text, app: app)
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func copyInstead(_ text: String, app: String) -> ActionOutcome {
        copy(text)
        return .failed("Couldn't write into \(app); copied instead")
    }
}

/// The Accessibility path: honoured by Cocoa, WebKit and Chromium editable
/// fields; ignored without an error by terminals and some Qt and Java apps,
/// which is why the value is read back.
enum AXWriter {
    static func write(_ text: String, insertBelow: Bool) -> Bool {
        guard let element = focusedElement() else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue else {
            return false
        }
        if insertBelow, let range = selectedRange(of: element) {
            var collapsed = CFRange(location: range.location + range.length, length: 0)
            if let value = AXValueCreate(.cfRange, &collapsed) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            }
        }
        let before = string(kAXValueAttribute, of: element)
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else { return false }
        return verified(text, before: before, element: element)
    }

    /// True when the element's value changed, or, when it cannot be read, when
    /// the selection now reads as the new text.
    private static func verified(_ text: String, before: String?, element: AXUIElement) -> Bool {
        if let after = string(kAXValueAttribute, of: element) {
            if after == before { return before?.contains(text) == true }
            return true
        }
        guard let selected = string(kAXSelectedTextAttribute, of: element) else { return true }
        return selected.isEmpty || selected == text || text.hasSuffix(selected)
    }

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &range) else { return nil }
        return range
    }
}

/// The ⌘V path: the answer goes on the pasteboard flagged transient, ⌘V is
/// posted after 50 ms, and the previous contents come back after 300 ms.
enum PasteWriter {
    static func paste(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.take(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: PasteboardSnapshot.transientType)
        try? await Task.sleep(for: .milliseconds(50))
        guard KeyPress.commandV() else {
            snapshot.restore(to: pasteboard)
            return false
        }
        try? await Task.sleep(for: .milliseconds(300))
        snapshot.restore(to: pasteboard)
        return true
    }
}

// The pasteboard snapshot lives in Capture (SelectionReader.swift): one type, used by the ⌘C read and the ⌘V write.

/// A synthetic ⌘V at the HID tap, which the frontmost app receives.
enum KeyPress {
    static func commandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
