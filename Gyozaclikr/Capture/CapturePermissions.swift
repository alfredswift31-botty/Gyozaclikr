import AppKit
import ApplicationServices

// The two grants Capture owns. Accessibility prompts once through
// AXIsProcessTrustedWithOptions; Screen Recording once through
// CGRequestScreenCaptureAccess. After that the system stays silent, so a
// second request opens the matching System Settings pane instead
// (docs/research/system-integration.md §7).

final class CapturePermissions: PermissionReporting {
    static let accessibilityPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let screenRecordingPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    private let defaults: UserDefaults
    private let promptedKey = "capturePermissionsPrompted"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func state(of permission: Permission) -> PermissionState {
        switch permission {
        case .accessibility: AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .denied
        default: .unknown
        }
    }

    func request(_ permission: Permission) async -> PermissionState {
        switch permission {
        case .accessibility:
            if AXIsProcessTrusted() { return .granted }
            if hasPrompted(permission) {
                openSettings(for: permission)
            } else {
                markPrompted(permission)
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            return state(of: permission)
        case .screenRecording:
            if CGPreflightScreenCaptureAccess() { return .granted }
            if hasPrompted(permission) {
                openSettings(for: permission)
            } else {
                markPrompted(permission)
                _ = CGRequestScreenCaptureAccess()
            }
            return state(of: permission)
        default:
            return .unknown
        }
    }

    /// The Privacy & Security pane for the permission.
    func openSettings(for permission: Permission) {
        switch permission {
        case .accessibility: NSWorkspace.shared.open(Self.accessibilityPane)
        case .screenRecording: NSWorkspace.shared.open(Self.screenRecordingPane)
        default: break
        }
    }

    private func hasPrompted(_ permission: Permission) -> Bool {
        (defaults.stringArray(forKey: promptedKey) ?? []).contains(permission.rawValue)
    }

    private func markPrompted(_ permission: Permission) {
        var prompted = defaults.stringArray(forKey: promptedKey) ?? []
        guard !prompted.contains(permission.rawValue) else { return }
        prompted.append(permission.rawValue)
        defaults.set(prompted, forKey: promptedKey)
    }
}
