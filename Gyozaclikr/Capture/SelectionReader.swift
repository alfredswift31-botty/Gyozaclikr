import AppKit
import ApplicationServices
import Carbon

// Reads what the user selected in the frontmost app: Accessibility first,
// a simulated ⌘C second, nothing at all under Secure Input
// (docs/research/system-integration.md §1). The decisions that need no
// system call live in small pure types below so they can be tested.

// MARK: - Pure helpers

/// Accessibility reports screen rectangles with a top-left origin; AppKit
/// and `Selection.bounds` use the bottom-left of the primary display.
nonisolated enum ScreenGeometry {
    static func appKitRect(fromAXRect rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The inverse, for ScreenCaptureKit and `AXUIElementCopyElementAtPosition`.
    static func axRect(fromAppKitRect rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func axPoint(fromAppKitPoint point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// A drag from `start` to `end` as a rectangle, whatever the direction.
    static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// The height of the primary display, the one whose origin AppKit uses.
    @MainActor static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
}

/// Rough token count before the engine measures: about four characters each.
nonisolated enum TokenEstimate {
    static func estimate(_ text: String) -> Int { max(1, text.count / 4) }
}

/// Whether Replace can write back: a text-like role whose selected text is
/// settable. Chromium reports settability everywhere, hence the role check.
nonisolated enum AXEditability {
    static let editableRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]

    static func isEditable(role: String?, selectedTextSettable: Bool) -> Bool {
        guard selectedTextSettable, let role else { return false }
        return editableRoles.contains(role)
    }
}

/// Widens a text position to the word around it, in UTF-16 offsets as
/// Accessibility ranges are. Letters, digits and marks make a word; an
/// apostrophe or a hyphen joins two halves ("don't", "on-device").
nonisolated enum WordBoundary {
    struct Match: Hashable, Sendable {
        let word: String
        /// UTF-16 range in the text it was found in.
        let range: Range<Int>
    }

    static func word(in text: String, at offset: Int) -> Match? {
        let utf16 = Array(text.utf16)
        guard offset >= 0, offset < utf16.count else { return nil }
        let scalars = Array(text.unicodeScalars)
        // Map each UTF-16 offset to its scalar index so surrogate pairs stay whole.
        var scalarAt = [Int](repeating: 0, count: utf16.count + 1)
        var unit = 0
        for (index, scalar) in scalars.enumerated() {
            for _ in 0..<scalar.utf16.count { scalarAt[unit] = index; unit += 1 }
        }
        scalarAt[utf16.count] = scalars.count
        let here = scalarAt[offset]
        guard isWordScalar(scalars[here]) else { return nil }
        var lower = here
        while lower > 0, joins(scalars, at: lower - 1) { lower -= 1 }
        var upper = here + 1
        while upper < scalars.count, joins(scalars, at: upper) { upper += 1 }
        let word = String(String.UnicodeScalarView(scalars[lower..<upper]))
        let start = scalars[..<lower].reduce(0) { $0 + $1.utf16.count }
        return Match(word: word, range: start..<(start + word.utf16.count))
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        let p = scalar.properties
        return p.isAlphabetic || p.numericType != nil || p.generalCategory == .nonspacingMark
            || p.generalCategory == .spacingMark || scalar == "_"
    }

    /// Whether the scalar at `index` belongs to the word around it.
    private static func joins(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        let scalar = scalars[index]
        if isWordScalar(scalar) { return true }
        guard scalar == "'" || scalar == "’" || scalar == "-" else { return false }
        return index > 0 && index + 1 < scalars.count && isWordScalar(scalars[index - 1]) && isWordScalar(scalars[index + 1])
    }
}

/// Everything on a pasteboard, so a simulated ⌘C can put it back. Promised
/// types are skipped: reading them blocks or throws.
nonisolated struct PasteboardSnapshot: Hashable, Sendable {
    /// Clipboard managers skip writes that declare this (nspasteboard.org).
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    struct Item: Hashable, Sendable {
        var data: [String: Data]
    }

    let items: [Item]
    let changeCount: Int

    var isEmpty: Bool { items.allSatisfy(\.data.isEmpty) }

    static func take(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var data: [String: Data] = [:]
            for type in item.types where !isPromise(type) {
                if let value = item.data(forType: type) { data[type.rawValue] = value }
            }
            return Item(data: data)
        }
        return PasteboardSnapshot(items: items, changeCount: pasteboard.changeCount)
    }

    /// Put the contents back, flagged transient so the restore is not recorded as a new copy.
    @discardableResult
    func restore(to pasteboard: NSPasteboard, transient: Bool = true) -> Bool {
        pasteboard.clearContents()
        guard !isEmpty else { return true }
        let objects = items.map { item -> NSPasteboardItem in
            let object = NSPasteboardItem()
            for (type, data) in item.data { object.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            if transient { object.setData(Data(), forType: Self.transientType) }
            return object
        }
        return pasteboard.writeObjects(objects)
    }

    static func isPromise(_ type: NSPasteboard.PasteboardType) -> Bool {
        type == .fileContents || type.rawValue.lowercased().contains("promise")
    }
}

/// Did the simulated ⌘C land? The pasteboard's changeCount says so; past
/// `timeout` nothing was selected or the app blocked the copy.
nonisolated struct CopyProbe: Hashable, Sendable {
    enum Outcome: Hashable, Sendable { case changed, waiting, timedOut }

    let baseline: Int
    var timeout: TimeInterval = 0.15
    var interval: TimeInterval = 0.01
    /// The source app has finished its copy by then; the user has not copied again yet.
    var restoreDelay: TimeInterval = 0.3

    init(baseline: Int) { self.baseline = baseline }

    func outcome(changeCount: Int, elapsed: TimeInterval) -> Outcome {
        if changeCount != baseline { return .changed }
        return elapsed >= timeout ? .timedOut : .waiting
    }
}

// MARK: - The reader

final class SelectionReader: SelectionReading {
    /// Chromium builds its tree lazily: a second read after this succeeds where the first was empty.
    static let lazyTreeRetry: Duration = .milliseconds(60)
    /// Characters read either side of the pointer when widening to a word.
    private static let wordWindow = 64

    private let systemWide = AXUIElementCreateSystemWide()
    private var restoreTask: Task<Void, Never>?

    init() {}

    // MARK: SelectionReading

    func readSelection() async -> Result<Selection, CaptureFailure> {
        guard AXIsProcessTrusted() else { return .failure(.accessibilityDenied) }
        if let selection = await readViaAccessibility() { return .success(selection) }
        // Secure Input: a password field or a terminal with secure entry on. Never read, never post.
        if IsSecureEventInputEnabled() { return .failure(.secureInput) }
        return await readViaCopy()
    }

    func wordUnderPointer() async -> Selection? {
        guard AXIsProcessTrusted() else { return nil }
        let primaryHeight = ScreenGeometry.primaryHeight
        let point = ScreenGeometry.axPoint(fromAppKitPoint: NSEvent.mouseLocation, primaryHeight: primaryHeight)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &found) == .success,
              let element = found else { return nil }
        var cgPoint = point
        guard let pointValue = AXValueCreate(.cgPoint, &cgPoint),
              let hit = AX.range(element.parameterized(kAXRangeForPositionParameterizedAttribute, pointValue))
        else { return nil }
        let length = AX.int(element.attribute(kAXNumberOfCharactersAttribute)) ?? (hit.location + Self.wordWindow)
        let lower = max(0, hit.location - Self.wordWindow)
        let upper = min(length, hit.location + Self.wordWindow)
        guard upper > lower, let window = AX.string(element, range: CFRange(location: lower, length: upper - lower)),
              let match = WordBoundary.word(in: window, at: hit.location - lower) else { return nil }
        let wordRange = CFRange(location: lower + match.range.lowerBound, length: match.range.count)
        let bounds = AX.bounds(element, range: wordRange).map {
            ScreenGeometry.appKitRect(fromAXRect: $0, primaryHeight: primaryHeight)
        }
        return Selection(kind: .word, word: match.word, bounds: bounds, sourceApp: Self.frontmostApp())
    }

    // MARK: Accessibility

    /// The selection through Accessibility only: nil when the focused element
    /// has none, or exposes none. No key events, so the pill can call it on every mouse-up.
    func readViaAccessibility() async -> Selection? {
        if let selection = readFocusedSelection() { return selection }
        try? await Task.sleep(for: Self.lazyTreeRetry)
        return readFocusedSelection()
    }

    private func readFocusedSelection() -> Selection? {
        guard let raw = systemWide.attribute(kAXFocusedUIElementAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        let range = AX.range(element.attribute(kAXSelectedTextRangeAttribute))
        var text = AX.string(element.attribute(kAXSelectedTextAttribute)) ?? ""
        // Some views return an empty AXSelectedText beside a valid range.
        if text.isEmpty, let range, range.length > 0 {
            text = AX.string(element, range: range) ?? ""
        }
        guard !text.isEmpty else { return nil }
        let primaryHeight = ScreenGeometry.primaryHeight
        let bounds = range.flatMap { AX.bounds(element, range: $0) }.map {
            ScreenGeometry.appKitRect(fromAXRect: $0, primaryHeight: primaryHeight)
        }
        let role = AX.string(element.attribute(kAXRoleAttribute))
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        return Selection(kind: .text, text: text, bounds: bounds, sourceApp: Self.frontmostApp(),
                         isEditable: AXEditability.isEditable(role: role, selectedTextSettable: settable.boolValue),
                         tokenEstimate: TokenEstimate.estimate(text))
    }

    // MARK: ⌘C fallback

    private func readViaCopy() async -> Result<Selection, CaptureFailure> {
        let pasteboard = NSPasteboard.general
        // A pending restore from the last read would otherwise overwrite this copy.
        restoreTask?.cancel()
        let snapshot = PasteboardSnapshot.take(from: pasteboard)
        let probe = CopyProbe(baseline: snapshot.changeCount)
        guard Self.postCommandC() else { return .failure(.other("Couldn't send ⌘C to the app.")) }
        let started = Date.timeIntervalSinceReferenceDate
        var outcome = CopyProbe.Outcome.waiting
        while outcome == .waiting {
            try? await Task.sleep(for: .seconds(probe.interval))
            outcome = probe.outcome(changeCount: pasteboard.changeCount, elapsed: Date.timeIntervalSinceReferenceDate - started)
        }
        guard outcome == .changed else { return .failure(.nothingSelected) }
        let text = pasteboard.string(forType: .string) ?? ""
        restoreTask = Task {
            try? await Task.sleep(for: .seconds(probe.restoreDelay))
            guard !Task.isCancelled else { return }
            snapshot.restore(to: pasteboard)
        }
        guard !text.isEmpty else { return .failure(.nothingSelected) }
        return .success(Selection(kind: .text, text: text, sourceApp: Self.frontmostApp(), isEditable: false,
                                  tokenEstimate: TokenEstimate.estimate(text)))
    }

    private static func postCommandC() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    static func frontmostApp() -> SourceApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return SourceApp(pid: app.processIdentifier, name: app.localizedName ?? "", bundleIdentifier: app.bundleIdentifier)
    }
}

// MARK: - Accessibility plumbing

private extension AXUIElement {
    func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value
    }

    func parameterized(_ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(self, name as CFString, parameter, &value) == .success else { return nil }
        return value
    }
}

private enum AX {
    static func string(_ value: CFTypeRef?) -> String? {
        value as? String
    }

    static func int(_ value: CFTypeRef?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    static func range(_ value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    static func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect, AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }

    static func string(_ element: AXUIElement, range: CFRange) -> String? {
        var cfRange = range
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        return string(element.parameterized(kAXStringForRangeParameterizedAttribute, parameter))
    }

    /// Top-left-origin screen rectangle of a range, or nil (static web text often has none).
    static func bounds(_ element: AXUIElement, range: CFRange) -> CGRect? {
        var cfRange = range
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        guard let rect = rect(element.parameterized(kAXBoundsForRangeParameterizedAttribute, parameter)),
              rect.width > 0 || rect.height > 0 else { return nil }
        return rect
    }
}
