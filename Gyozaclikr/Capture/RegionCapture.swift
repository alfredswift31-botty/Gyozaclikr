import AppKit
import ScreenCaptureKit

// Region capture: a rubber band drawn over every screen, then one
// ScreenCaptureKit screenshot of the rectangle and Live Text over it
// (docs/research/system-integration.md §3). Screen Recording is checked
// first; a thrown capture is read as the monthly re-approval alert, retried
// once, then reported as denied.

final class RegionCapture: RegionCapturing {
    /// The alert's "Allow for one month" takes the user about this long.
    static let reapprovalRetryDelay: Duration = .seconds(1)
    /// Drags smaller than this are a click: cancelled, not captured.
    static let minimumSide: CGFloat = 4

    private let recognizer: TextRecognizer
    private var overlay: RegionOverlay?

    init(recognizer: TextRecognizer = TextRecognizer()) {
        self.recognizer = recognizer
    }

    // MARK: RegionCapturing

    func captureRegion() async -> Result<Selection, CaptureFailure> {
        guard Self.ensureScreenRecording() else { return .failure(.screenRecordingDenied) }
        guard overlay == nil else { return .failure(.cancelled) }
        let overlay = RegionOverlay()
        self.overlay = overlay
        let rect = await overlay.select()
        self.overlay = nil
        guard let rect, rect.width >= Self.minimumSide, rect.height >= Self.minimumSide else {
            return .failure(.cancelled)
        }
        // The overlays are ordered out; give the window server a frame to drop them.
        try? await Task.sleep(for: .milliseconds(60))
        let image: ImagePayload
        let captured = await captureImage(of: rect, excluding: overlay.windowIDs)
        switch captured {
        case .success(let payload): image = payload
        case .failure(let failure): return .failure(failure)
        }
        let ocr = await recognize(image)
        return .success(Selection(kind: .image, text: ocr.text.isEmpty ? nil : ocr.text, image: image, bounds: rect,
                                  sourceApp: SelectionReader.frontmostApp(), isEditable: false,
                                  tokenEstimate: ocr.text.isEmpty ? nil : TokenEstimate.estimate(ocr.text),
                                  ocrWordCount: ocr.wordCount))
    }

    /// Cancel a capture in progress (the coordinator's Esc, or the app quitting).
    func cancel() {
        overlay?.cancel()
    }

    // MARK: Capture

    /// One screenshot of `rect`, given in AppKit screen coordinates, at the
    /// screen's native scale. No overlay; the tests use it directly.
    func captureImage(of rect: CGRect, excluding windowIDs: [CGWindowID] = []) async -> Result<ImagePayload, CaptureFailure> {
        guard Self.ensureScreenRecording() else { return .failure(.screenRecordingDenied) }
        let rect = rect.integral
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 1
        let axRect = ScreenGeometry.axRect(fromAppKitRect: rect, primaryHeight: ScreenGeometry.primaryHeight)
        do {
            let cgImage = try await Self.screenshot(axRect, scale: scale, excluding: windowIDs)
            guard let payload = ImagePayload(cgImage: cgImage, pointSize: rect.size, scale: scale) else {
                return .failure(.other("Couldn't encode the capture."))
            }
            return .success(payload)
        } catch {
            // Most likely the re-approval alert: wait for the click, try once more.
            try? await Task.sleep(for: Self.reapprovalRetryDelay)
            do {
                let cgImage = try await Self.screenshot(axRect, scale: scale, excluding: windowIDs)
                guard let payload = ImagePayload(cgImage: cgImage, pointSize: rect.size, scale: scale) else {
                    return .failure(.other("Couldn't encode the capture."))
                }
                return .success(payload)
            } catch {
                return .failure(.screenRecordingDenied)
            }
        }
    }

    /// The macOS 26 rect screenshot first (display-agnostic, points, top-left
    /// origin); the content-filter path when it yields no image.
    private static func screenshot(_ axRect: CGRect, scale: CGFloat, excluding windowIDs: [CGWindowID]) async throws -> CGImage {
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr
        configuration.displayIntent = .canonical
        configuration.width = Int(axRect.width * scale)
        configuration.height = Int(axRect.height * scale)
        let output = try await SCScreenshotManager.captureScreenshot(rect: axRect, configuration: configuration)
        if let image = output.sdrImage { return image }
        return try await filteredScreenshot(axRect, scale: scale, excluding: windowIDs)
    }

    private static func filteredScreenshot(_ axRect: CGRect, scale: CGFloat, excluding windowIDs: [CGWindowID]) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.intersects(axRect) }) ?? content.displays.first else {
            throw CaptureFailure.other("No display to capture.")
        }
        let excluded = content.windows.filter { windowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = axRect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        // Width and height are pixels while the rect is points: the classic blurry-capture bug.
        configuration.width = Int(axRect.width * scale)
        configuration.height = Int(axRect.height * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private func recognize(_ image: ImagePayload) async -> OCRResult {
        guard let cgImage = image.cgImage else { return .empty }
        return (try? await recognizer.recognize(cgImage)) ?? .empty
    }

    /// Preflight, then the system prompt when it has never been shown.
    private static func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }
}

// MARK: - Overlay

/// One borderless window per screen, dimmed, with the rubber band. Esc or
/// a click without a drag cancels. The result is the rectangle in AppKit
/// screen coordinates, or nil.
final class RegionOverlay {
    private var windows: [RegionOverlayWindow] = []
    private var continuation: CheckedContinuation<CGRect?, Never>?
    private var dragStart: CGPoint?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?

    var windowIDs: [CGWindowID] { windows.map { CGWindowID($0.windowNumber) } }

    func select() async -> CGRect? {
        previousApp = NSWorkspace.shared.frontmostApplication
        windows = NSScreen.screens.map { screen in
            let window = RegionOverlayWindow(screen: screen)
            window.overlayView.overlay = self
            return window
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            // Local monitors run on the main thread whatever the block's declared isolation.
            MainActor.assumeIsolated { self?.cancel() }
            return nil
        }
        NSCursor.crosshair.push()
        NSApp.activate()
        for window in windows { window.orderFrontRegardless() }
        windows.first { $0.frame.contains(NSEvent.mouseLocation) }?.makeKey()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() { finish(nil) }

    // Called by the views with points in AppKit screen coordinates.

    func began(at point: CGPoint) {
        dragStart = point
        broadcast(ScreenGeometry.rect(from: point, to: point))
    }

    func dragged(to point: CGPoint) {
        guard let dragStart else { return }
        broadcast(ScreenGeometry.rect(from: dragStart, to: point))
    }

    func ended(at point: CGPoint) {
        guard let dragStart else { return cancel() }
        finish(ScreenGeometry.rect(from: dragStart, to: point))
    }

    private func broadcast(_ rect: CGRect) {
        for window in windows { window.overlayView.show(screenRect: rect) }
    }

    private func finish(_ rect: CGRect?) {
        guard let continuation else { return }
        self.continuation = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NSCursor.pop()
        for window in windows {
            window.overlayView.overlay = nil
            window.orderOut(nil)
        }
        windows = []
        // Give focus back so the box opens beside the app the user was in.
        if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            _ = previousApp.activate()
        }
        CATransaction.flush()
        continuation.resume(returning: rect)
    }
}

final class RegionOverlayWindow: NSWindow {
    let overlayView: RegionOverlayView

    init(screen: NSScreen) {
        overlayView = RegionOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = overlayView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The dimmed backdrop with a clear window where the rubber band is.
final class RegionOverlayView: NSView {
    weak var overlay: RegionOverlay?
    private var band: CGRect?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    func show(screenRect: CGRect) {
        guard let window else { return }
        band = window.convertFromScreen(screenRect)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        guard let band, let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(band)
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: band.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        outline.stroke()
        let label = "\(Int(band.width)) × \(Int(band.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        var origin = CGPoint(x: band.maxX - size.width, y: band.minY - size.height - 4)
        if origin.y < 0 { origin.y = band.maxY + 4 }
        let plate = CGRect(x: origin.x - 4, y: origin.y - 2, width: size.width + 8, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: plate, xRadius: 3, yRadius: 3).fill()
        label.draw(at: origin, withAttributes: attributes)
    }

    private func screenPoint(_ event: NSEvent) -> CGPoint {
        guard let window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    override func mouseDown(with event: NSEvent) { overlay?.began(at: screenPoint(event)) }
    override func mouseDragged(with event: NSEvent) { overlay?.dragged(to: screenPoint(event)) }
    override func mouseUp(with event: NSEvent) { overlay?.ended(at: screenPoint(event)) }
    override func rightMouseDown(with event: NSEvent) { overlay?.cancel() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { overlay?.cancel() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { overlay?.cancel() }
}
