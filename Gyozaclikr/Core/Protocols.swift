import Foundation

// The seams between modules. Each module implements its protocol; the
// coordinator in App wires them. Keep these minimal: a module that needs
// more should extend its own types, not these.

/// Capture: the current selection from the frontmost app.
protocol SelectionReading: AnyObject {
    func readSelection() async -> Result<Selection, CaptureFailure>
    /// The word under the pointer, for Define, when nothing is selected.
    func wordUnderPointer() async -> Selection?
}

/// Capture: a region the user draws, as an image with its OCR text.
protocol RegionCapturing: AnyObject {
    func captureRegion() async -> Result<Selection, CaptureFailure>
}

/// Capture: the global shortcut. Tap summons the box; hold starts region capture.
protocol HotKeyHandling: AnyObject {
    var onTap: (() -> Void)? { get set }
    var onHold: (() -> Void)? { get set }
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool
    func unregister()
}

/// Router: what to do with a request.
protocol Routing: Sendable {
    func route(_ request: Request, engines: [EngineKind: Set<EngineCapability>]) -> Route
}

/// Actions: perform proposals and result actions.
protocol ActionPerforming: AnyObject {
    func perform(_ proposal: ActionProposal) async -> ActionOutcome
    func perform(_ action: ResultAction, answer: Answer, selection: Selection) async -> ActionOutcome
    /// The system dictionary's definition, no model.
    func define(_ word: String) -> String?
}

/// Each module reports the permissions it owns.
protocol PermissionReporting: AnyObject {
    func state(of permission: Permission) -> PermissionState
    /// Prompt the system dialog or open the Settings pane for it.
    func request(_ permission: Permission) async -> PermissionState
}
