import AppKit
import Carbon

// The global shortcut. Carbon's RegisterEventHotKey is the one API that
// swallows the key without any permission (docs/research/system-integration.md §2).
// A tap summons the box on the current selection; a hold starts region
// capture. The tap-versus-hold decision is a pure state machine so it can be
// tested without Carbon.

/// Press at t0, release at t1 or a timer at t0 + 300 ms: which gesture was it?
nonisolated struct HotKeyGesture: Hashable, Sendable {
    /// Held this long, the press becomes a hold.
    static let holdThreshold: TimeInterval = 0.3

    enum Event: Hashable, Sendable {
        case pressed(at: TimeInterval)
        case released(at: TimeInterval)
        case timerFired(at: TimeInterval)
    }

    enum Action: Hashable, Sendable {
        case none
        /// Arm a timer for `holdThreshold` from now and feed `timerFired` back.
        case startHoldTimer
        case tap
        case hold
    }

    private(set) var pressedAt: TimeInterval?
    private(set) var holdFired = false

    var isPressed: Bool { pressedAt != nil }

    mutating func handle(_ event: Event) -> Action {
        switch event {
        case .pressed(let now):
            // Key repeat delivers more presses while held: only the first counts.
            guard pressedAt == nil else { return .none }
            pressedAt = now
            holdFired = false
            return .startHoldTimer
        case .released(let now):
            guard let start = pressedAt else { return .none }
            pressedAt = nil
            defer { holdFired = false }
            if holdFired { return .none }
            // A late timer must not turn a long press into a tap.
            return now - start < Self.holdThreshold ? .tap : .hold
        case .timerFired(let now):
            // A timer from an earlier press that was released already: the
            // elapsed check drops it, because a new press restarted the clock.
            guard let start = pressedAt, !holdFired, now - start >= Self.holdThreshold else { return .none }
            holdFired = true
            return .hold
        }
    }
}

/// The shortcut as the menu shows it ("⌃Space").
nonisolated enum HotKeyDisplay {
    static func string(keyCode: UInt32, modifiers: UInt32) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName(keyCode)
    }

    private static let names: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5",
        kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func keyName(_ keyCode: UInt32) -> String {
        names[Int(keyCode)] ?? "Key \(keyCode)"
    }
}

/// The registered shortcut. One instance; the coordinator sets `onTap` and
/// `onHold` and calls `register()`.
final class HotKey: HotKeyHandling {
    nonisolated static let defaultKeyCode = UInt32(kVK_Space)
    nonisolated static let defaultModifiers = UInt32(controlKey)
    /// "GZCK": tells our handler's events from any other Carbon client's.
    private nonisolated static let signature: OSType = 0x475A_434B

    var onTap: (() -> Void)?
    var onHold: (() -> Void)?

    private let defaults: UserDefaults
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var gesture = HotKeyGesture()
    private var holdTimer: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// The persisted combination; Control+Space until the user changes it.
    var keyCode: UInt32 {
        defaults.object(forKey: SettingsKey.hotKeyCode) == nil
            ? Self.defaultKeyCode : UInt32(clamping: defaults.integer(forKey: SettingsKey.hotKeyCode))
    }

    var modifiers: UInt32 {
        defaults.object(forKey: SettingsKey.hotKeyModifiers) == nil
            ? Self.defaultModifiers : UInt32(clamping: defaults.integer(forKey: SettingsKey.hotKeyModifiers))
    }

    var displayString: String { HotKeyDisplay.string(keyCode: keyCode, modifiers: modifiers) }

    var isRegistered: Bool { hotKeyRef != nil }

    /// Register the persisted combination.
    @discardableResult
    func register() -> Bool { register(keyCode: keyCode, modifiers: modifiers) }

    /// Persist and register a combination; false when another app holds it
    /// (the previous registration, if any, is released either way).
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        defaults.set(Int(keyCode), forKey: SettingsKey.hotKeyCode)
        defaults.set(Int(modifiers), forKey: SettingsKey.hotKeyModifiers)
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        return true
    }

    func unregister() {
        holdTimer?.cancel()
        holdTimer = nil
        gesture = HotKeyGesture()
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var ref: EventHandlerRef?
        let status = InstallEventHandler(GetEventDispatcherTarget(), hotKeyEventHandler, ItemCount(types.count), &types, userData, &ref)
        if status == noErr { handlerRef = ref }
    }

    /// Called by the Carbon handler on the main thread.
    fileprivate func handleCarbonEvent(id: EventHotKeyID, kind: UInt32) {
        guard id.signature == Self.signature else { return }
        let now = Date.timeIntervalSinceReferenceDate
        switch Int(kind) {
        case kEventHotKeyPressed: perform(gesture.handle(.pressed(at: now)))
        case kEventHotKeyReleased: perform(gesture.handle(.released(at: now)))
        default: break
        }
    }

    private func perform(_ action: HotKeyGesture.Action) {
        switch action {
        case .none:
            break
        case .startHoldTimer:
            holdTimer?.cancel()
            holdTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(HotKeyGesture.holdThreshold), tolerance: .milliseconds(5))
                guard !Task.isCancelled, let self else { return }
                self.perform(self.gesture.handle(.timerFired(at: Date.timeIntervalSinceReferenceDate)))
            }
        case .tap:
            holdTimer?.cancel()
            onTap?()
        case .hold:
            holdTimer?.cancel()
            onHold?()
        }
    }
}

/// The C entry point Carbon calls; it only forwards to the instance in `userData`.
private nonisolated func hotKeyEventHandler(_ call: EventHandlerCallRef?, _ event: EventRef?,
                                            _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, ByteCount(MemoryLayout<EventHotKeyID>.size), nil, &id)
    guard status == noErr else { return status }
    let kind = GetEventKind(event)
    let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
    // Carbon dispatches hot keys on the main thread.
    MainActor.assumeIsolated { hotKey.handleCarbonEvent(id: id, kind: kind) }
    return noErr
}
