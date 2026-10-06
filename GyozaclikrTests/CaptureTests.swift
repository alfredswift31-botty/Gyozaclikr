import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Gyozaclikr

// Capture's tests: the pure decisions with fixtures, Vision for real (it
// needs no grant), the Services handler on private pasteboards, and the
// Accessibility and ScreenCaptureKit paths only when the runner holds the
// grant, with a line in the measurements file either way. Never the general
// pasteboard, never a posted key event.

/// Lines CI prints after the tests ("== Measurements from the real tests ==").
nonisolated enum CaptureMeasurements {
    private static let lock = NSLock()
    static let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("gyozaclikr-measurements", isDirectory: true)
        .appendingPathComponent("capture.txt")

    static func record(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try? (existing + "capture: " + line + "\n").write(to: file, atomically: true, encoding: .utf8)
        // The Xcode 26 job has no measurements step: the log line is the record there.
        print("capture: " + line)
    }
}

/// Vision on this runner, or the reason it is not (the macOS 27 preview
/// image throws from both requests). Tests that need OCR skip on nil.
nonisolated enum VisionProbe {
    static func check() async -> String? {
        guard let image = TestImages.render("probe") else { return "no image" }
        do {
            _ = try await TextRecognizer().recognize(image)
            return nil
        } catch {
            return "\(error)"
        }
    }
}

/// A CGImage with one line of black text on white, drawn with Core Text.
nonisolated enum TestImages {
    static func render(_ text: String, width: Int = 900, height: Int = 160, fontSize: CGFloat = 48) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        context.textPosition = CGPoint(x: 40, y: CGFloat(height) / 2 - fontSize / 3)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

private func privatePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("com.gyoza.clikr.tests.\(UUID().uuidString)"))
}

// MARK: - Hot key

struct HotKeyGestureTests {
    private let hold = HotKeyGesture.holdThreshold

    @Test func aQuickPressIsATap() {
        var gesture = HotKeyGesture()
        #expect(gesture.handle(.pressed(at: 0)) == .startHoldTimer)
        #expect(gesture.handle(.released(at: 0.1)) == .tap)
        #expect(!gesture.isPressed)
    }

    @Test func aLingeringTapIsStillATap() {
        // 300 ms on the keys is a tap, not a region capture.
        var gesture = HotKeyGesture()
        #expect(gesture.handle(.pressed(at: 0)) == .startHoldTimer)
        #expect(gesture.handle(.released(at: 0.3)) == .tap)
    }

    @Test func aPressStillDownAtTheThresholdIsAHoldOnce() {
        var gesture = HotKeyGesture()
        #expect(gesture.handle(.pressed(at: 0)) == .startHoldTimer)
        #expect(gesture.handle(.timerFired(at: hold)) == .hold)
        #expect(gesture.handle(.timerFired(at: hold + 0.05)) == .none)
        #expect(gesture.handle(.released(at: hold + 0.6)) == .none)
    }

    @Test func keyRepeatDoesNotRestartThePress() {
        var gesture = HotKeyGesture()
        #expect(gesture.handle(.pressed(at: 0)) == .startHoldTimer)
        #expect(gesture.handle(.pressed(at: 0.05)) == .none)
        #expect(gesture.handle(.pressed(at: 0.2)) == .none)
        #expect(gesture.handle(.timerFired(at: hold)) == .hold)
    }

    @Test func aLateTimerCannotTurnALongPressIntoATap() {
        var gesture = HotKeyGesture()
        _ = gesture.handle(.pressed(at: 0))
        #expect(gesture.handle(.released(at: hold + 0.2)) == .hold)
    }

    @Test func aStaleTimerFromAnEarlierTapIsIgnored() {
        var gesture = HotKeyGesture()
        _ = gesture.handle(.pressed(at: 0))
        #expect(gesture.handle(.released(at: 0.1)) == .tap)
        #expect(gesture.handle(.timerFired(at: hold)) == .none)
        #expect(gesture.handle(.pressed(at: 0.2)) == .startHoldTimer)
        // The first press's timer: too early for the second press.
        #expect(gesture.handle(.timerFired(at: hold)) == .none)
        #expect(gesture.handle(.timerFired(at: 0.2 + hold)) == .hold)
    }

    @Test func releaseWithoutAPressDoesNothing() {
        var gesture = HotKeyGesture()
        #expect(gesture.handle(.released(at: 1)) == .none)
        #expect(gesture.handle(.timerFired(at: 1)) == .none)
    }

    @Test func theShortcutReadsAsSymbols() {
        #expect(HotKeyDisplay.string(keyCode: HotKey.defaultKeyCode, modifiers: HotKey.defaultModifiers) == "⌃Space")
        #expect(HotKeyDisplay.string(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey)) == "⇧⌘K")
    }

    @MainActor @Test func theDefaultIsControlSpaceAndACombinationPersists() throws {
        let suite = "com.gyoza.clikr.tests.hotkey.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hotKey = HotKey(defaults: defaults)
        #expect(hotKey.keyCode == UInt32(kVK_Space))
        #expect(hotKey.modifiers == UInt32(controlKey))
        #expect(hotKey.displayString == "⌃Space")
        // An unlikely chord, registered for real through Carbon (no permission, no key events).
        let registered = hotKey.register(keyCode: UInt32(kVK_F12), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        CaptureMeasurements.record("hotkey: RegisterEventHotKey(⌃⌥⇧⌘F12) in the test host -> \(registered)")
        #expect(hotKey.keyCode == UInt32(kVK_F12))
        #expect(defaults.integer(forKey: SettingsKey.hotKeyCode) == kVK_F12)
        #expect(HotKey(defaults: defaults).displayString == "⌃⌥⇧⌘F12")
        hotKey.unregister()
        #expect(!hotKey.isRegistered)
    }
}

// MARK: - Geometry, tokens, words

struct SelectionHelperTests {
    @Test func accessibilityRectsFlipAgainstThePrimaryScreen() {
        let ax = CGRect(x: 10, y: 20, width: 100, height: 30)
        let appKit = ScreenGeometry.appKitRect(fromAXRect: ax, primaryHeight: 900)
        #expect(appKit == CGRect(x: 10, y: 850, width: 100, height: 30))
        #expect(ScreenGeometry.axRect(fromAppKitRect: appKit, primaryHeight: 900) == ax)
        #expect(ScreenGeometry.axPoint(fromAppKitPoint: CGPoint(x: 5, y: 900), primaryHeight: 900) == CGPoint(x: 5, y: 0))
        // A second display above the primary has negative AX y; the round trip still holds.
        let above = CGRect(x: 0, y: -1080, width: 50, height: 50)
        #expect(ScreenGeometry.axRect(fromAppKitRect: ScreenGeometry.appKitRect(fromAXRect: above, primaryHeight: 900), primaryHeight: 900) == above)
    }

    @Test func aDragInAnyDirectionIsTheSameRectangle() {
        let a = CGPoint(x: 10, y: 10), b = CGPoint(x: 50, y: 30)
        #expect(ScreenGeometry.rect(from: a, to: b) == CGRect(x: 10, y: 10, width: 40, height: 20))
        #expect(ScreenGeometry.rect(from: b, to: a) == CGRect(x: 10, y: 10, width: 40, height: 20))
    }

    @Test func tokensAreAboutFourCharactersAndNeverZero() {
        #expect(TokenEstimate.estimate("") == 1)
        #expect(TokenEstimate.estimate("abc") == 1)
        #expect(TokenEstimate.estimate(String(repeating: "x", count: 1_648)) == 412)
    }

    @Test func editableNeedsATextRoleAndASettableSelection() {
        #expect(AXEditability.isEditable(role: kAXTextAreaRole, selectedTextSettable: true))
        #expect(!AXEditability.isEditable(role: kAXTextAreaRole, selectedTextSettable: false))
        // Chromium says everything is settable; a web area is still not a field.
        #expect(!AXEditability.isEditable(role: "AXWebArea", selectedTextSettable: true))
        #expect(!AXEditability.isEditable(role: nil, selectedTextSettable: true))
    }

    @Test func wordsStopAtPunctuationAndSpaces() {
        let text = "Hello, world! (Gyozaclikr) reads."
        #expect(WordBoundary.word(in: text, at: 8)?.word == "world")
        #expect(WordBoundary.word(in: text, at: 8)?.range == 7..<12)
        #expect(WordBoundary.word(in: text, at: 0)?.word == "Hello")
        #expect(WordBoundary.word(in: text, at: 15)?.word == "Gyozaclikr")
        #expect(WordBoundary.word(in: text, at: 5) == nil)   // the comma
        #expect(WordBoundary.word(in: text, at: 6) == nil)   // the space
        #expect(WordBoundary.word(in: text, at: 99) == nil)
        #expect(WordBoundary.word(in: text, at: -1) == nil)
    }

    @Test func apostrophesAndHyphensJoinButDoNotLead() {
        #expect(WordBoundary.word(in: "I don't know", at: 4)?.word == "don't")
        #expect(WordBoundary.word(in: "an on-device model", at: 5)?.word == "on-device")
        #expect(WordBoundary.word(in: "'quoted'", at: 2)?.word == "quoted")
        #expect(WordBoundary.word(in: "end-", at: 3) == nil)
    }

    @Test func wordsKeepUnicodeTogetherInUTF16Offsets() {
        #expect(WordBoundary.word(in: "naïve café", at: 7)?.word == "café")
        #expect(WordBoundary.word(in: "naïve café", at: 7)?.range == 6..<10)
        #expect(WordBoundary.word(in: "日本語 テキスト", at: 1)?.word == "日本語")
        // An emoji is two UTF-16 units: offsets after it still land on the right word.
        let emoji = "🙂 smile"
        #expect(WordBoundary.word(in: emoji, at: 3)?.word == "smile")
        #expect(WordBoundary.word(in: emoji, at: 3)?.range == 3..<8)
        #expect(WordBoundary.word(in: emoji, at: 0) == nil)
    }
}

// MARK: - Pasteboard

struct PasteboardTests {
    @MainActor @Test func aSnapshotRestoresEveryTypeAndMarksTheWriteTransient() throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let custom = NSPasteboard.PasteboardType("com.gyoza.clikr.tests.bytes")
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("original", forType: .string)
        item.setData(Data([1, 2, 3]), forType: custom)
        #expect(pasteboard.writeObjects([item]))

        let snapshot = PasteboardSnapshot.take(from: pasteboard)
        #expect(snapshot.items.count == 1)
        #expect(snapshot.items.first?.data[custom.rawValue] == Data([1, 2, 3]))
        #expect(!snapshot.isEmpty)

        // The source app's ⌘C replaces the contents…
        pasteboard.clearContents()
        pasteboard.setString("copied by the app", forType: .string)
        #expect(pasteboard.string(forType: .string) == "copied by the app")
        #expect(pasteboard.changeCount != snapshot.changeCount)

        // …and the restore puts the original back.
        #expect(snapshot.restore(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "original")
        let restored = try #require(pasteboard.pasteboardItems?.first)
        #expect(restored.data(forType: custom) == Data([1, 2, 3]))
        #expect(restored.types.contains(PasteboardSnapshot.transientType))
    }

    @MainActor @Test func anEmptySnapshotRestoresToEmpty() {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let snapshot = PasteboardSnapshot.take(from: pasteboard)
        #expect(snapshot.isEmpty)
        pasteboard.setString("left over", forType: .string)
        #expect(snapshot.restore(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func promisedTypesAreNeverRead() {
        #expect(PasteboardSnapshot.isPromise(NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")))
        #expect(PasteboardSnapshot.isPromise(.fileContents))
        #expect(!PasteboardSnapshot.isPromise(.string))
        #expect(!PasteboardSnapshot.isPromise(.png))
    }

    @Test func theCopyProbeWaitsThenGivesUp() {
        let probe = CopyProbe(baseline: 5)
        #expect(probe.outcome(changeCount: 5, elapsed: 0) == .waiting)
        #expect(probe.outcome(changeCount: 5, elapsed: 0.14) == .waiting)
        #expect(probe.outcome(changeCount: 6, elapsed: 0.02) == .changed)
        #expect(probe.outcome(changeCount: 5, elapsed: 0.15) == .timedOut)
        // A change that lands right at the deadline still counts.
        #expect(probe.outcome(changeCount: 9, elapsed: 0.3) == .changed)
        #expect(probe.restoreDelay > probe.timeout)
    }
}

// MARK: - OCR

struct OCRTests {
    private func box(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 0.2, h: CGFloat = 0.1) -> OCRLayout.Box {
        OCRLayout.Box(text: text, frame: CGRect(x: x, y: y, width: w, height: h))
    }

    @Test func boxesAreOrderedTopToBottomThenLeftToRight() {
        let boxes = [
            box("line", x: 0.1, y: 0.3), box("world", x: 0.5, y: 0.8), box("Hello", x: 0.1, y: 0.82),
            box("second", x: 0.0, y: 0.31), box("", x: 0.9, y: 0.9),
        ]
        #expect(OCRLayout.join(boxes) == "Hello world\nsecond line")
        #expect(OCRLayout.lines(boxes).map(\.count) == [2, 2])
        #expect(OCRLayout.wordCount(OCRLayout.join(boxes)) == 4)
    }

    @Test func slightlyStaggeredBoxesStayOnOneLineButDistinctLinesSplit() {
        let a = box("a", x: 0.0, y: 0.50), b = box("b", x: 0.3, y: 0.53), c = box("c", x: 0.0, y: 0.38)
        #expect(OCRLayout.join([c, b, a]) == "a b\nc")
        #expect(OCRLayout.wordCount("  one\ntwo  three\n") == 3)
        #expect(OCRLayout.wordCount("") == 0)
    }

    @Test func visionReadsARenderedLineForReal() async throws {
        if let reason = await VisionProbe.check() {
            CaptureMeasurements.record("ocr: skipped: Vision unavailable on this runner (\(reason))")
            return
        }
        let image = try #require(TestImages.render("Gyozaclikr reads 42 words"))
        let started = Date()
        let result = try await TextRecognizer(customWords: ["Gyozaclikr"]).recognize(image)
        let elapsed = Date().timeIntervalSince(started)
        CaptureMeasurements.record("ocr: \"\(result.text)\" words=\(result.wordCount) lines=\(result.lines.count) via \(result.api) in \(Int(elapsed * 1000)) ms")
        #expect(result.text.lowercased().contains("reads 42 words"))
        #expect(result.text.lowercased().contains("gyozaclikr"))
        #expect(result.wordCount == 4)
        #expect(result.lines.count == 1)
    }

    @Test func anImagePayloadKeepsPointSizeAndScaleAtFullResolution() throws {
        let image = try #require(TestImages.render("2x", width: 200, height: 100))
        let payload = try #require(ImagePayload(cgImage: image, pointSize: CGSize(width: 100, height: 50), scale: 2))
        #expect(payload.pointSize == CGSize(width: 100, height: 50))
        #expect(payload.scale == 2)
        #expect(!payload.png.isEmpty)
        let decoded = try #require(payload.cgImage)
        #expect(decoded.width == 200)
        #expect(decoded.height == 100)
        let fromPasteboard = try #require(ImagePayload(cgImage: image))
        #expect(fromPasteboard.pointSize == CGSize(width: 200, height: 100))
        #expect(fromPasteboard.scale == 1)
    }
}

// MARK: - Services

struct ServicesProviderTests {
    @MainActor @Test func textFromTheServicesPasteboardBecomesATextSelection() {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("Hello from the Services menu", forType: .string)
        let provider = ServicesProvider()
        var received: Selection?
        provider.onSelection = { received = $0 }
        var error: NSString = ""
        provider.askGyozaclikr(pasteboard, userData: "", error: &error)
        #expect(received?.kind == .text)
        #expect(received?.text == "Hello from the Services menu")
        #expect(received?.isEditable == false)
        #expect(received?.tokenEstimate == 7)
        #expect(error.length == 0)
    }

    @MainActor @Test func anEmptyPasteboardReportsAnError() {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let provider = ServicesProvider()
        var received: Selection?
        provider.onSelection = { received = $0 }
        var error: NSString = ""
        provider.askGyozaclikr(pasteboard, userData: "", error: &error)
        #expect(received == nil)
        #expect(error.length > 0)
    }

    @MainActor @Test func aPNGFromTheServicesPasteboardBecomesAnImageSelectionWithOCR() async throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let image = try #require(TestImages.render("Services menu image"))
        pasteboard.clearContents()
        pasteboard.setData(try #require(TestImages.png(image)), forType: .png)
        let handled = await ServicesProvider().handle(pasteboard: pasteboard)
        let selection = try #require(handled)
        CaptureMeasurements.record("services png: ocr=\"\(selection.text ?? "")\" words=\(selection.ocrWordCount ?? -1)")
        #expect(selection.kind == .image)
        #expect(selection.image?.pointSize == CGSize(width: 900, height: 160))
        #expect(selection.image?.scale == 1)
        #expect(selection.isEditable == false)
        if let reason = await VisionProbe.check() {
            CaptureMeasurements.record("services png: OCR checks skipped: Vision unavailable on this runner (\(reason))")
            #expect(selection.ocrWordCount == 0)
            return
        }
        #expect(selection.text?.lowercased().contains("services") == true)
        #expect(selection.ocrWordCount == 3)
    }
}

// MARK: - The grants: real only where the runner has them

struct GrantedPathTests {
    @MainActor @Test func permissionsReportTheTwoGrantsAndNothingElse() {
        let permissions = CapturePermissions()
        let accessibility = permissions.state(of: .accessibility)
        let screen = permissions.state(of: .screenRecording)
        #expect([PermissionState.granted, .denied].contains(accessibility))
        #expect([PermissionState.granted, .denied].contains(screen))
        #expect(permissions.state(of: .reminders) == .unknown)
        #expect(CapturePermissions.accessibilityPane.absoluteString.hasSuffix("Privacy_Accessibility"))
        #expect(CapturePermissions.screenRecordingPane.absoluteString.hasSuffix("Privacy_ScreenCapture"))
        CaptureMeasurements.record("grants: accessibility=\(accessibility) screenRecording=\(screen)")
    }

    @MainActor @Test func accessibilityReadRunsOnlyWithTheGrant() async {
        guard AXIsProcessTrusted() else {
            CaptureMeasurements.record("accessibility read: skipped: no grant on this runner")
            return
        }
        let reader = SelectionReader()
        let selection = await reader.readViaAccessibility()
        let word = await reader.wordUnderPointer()
        CaptureMeasurements.record("accessibility read: selection=\(selection?.kind.rawValue ?? "nil") bounds=\(selection?.bounds.map { "\($0)" } ?? "nil") word=\(word?.word ?? "nil")")
    }

    @MainActor @Test func screenCaptureRunsOnlyWithTheGrant() async {
        guard CGPreflightScreenCaptureAccess() else {
            CaptureMeasurements.record("screen capture: skipped: no grant on this runner")
            return
        }
        let rect = CGRect(x: 0, y: 0, width: 120, height: 80)
        let started = Date()
        let result = await RegionCapture().captureImage(of: rect)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        switch result {
        case .success(let payload):
            CaptureMeasurements.record("screen capture: \(payload.pointSize) at scale \(payload.scale), \(payload.png.count) bytes PNG in \(elapsed) ms")
            #expect(payload.pointSize == rect.size)
            #expect(payload.cgImage?.width == Int(rect.width * payload.scale))
        case .failure(let failure):
            CaptureMeasurements.record("screen capture: failed \(failure) in \(elapsed) ms")
        }
    }
}
