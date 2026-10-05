import AppKit
import Contacts
import EventKit

/// The grants the actions need: Reminders and Calendar through EventKit,
/// Automation for Notes (no status API: not determined until the first
/// script runs), Contacts for "mail <name>". Accessibility and Screen
/// Recording belong to Capture.
final class ActionPermissions: PermissionReporting {
    init() {}

    func state(of permission: Permission) -> PermissionState {
        switch permission {
        case .reminders: return Self.state(EKEventStore.authorizationStatus(for: .reminder))
        case .calendar: return Self.state(EKEventStore.authorizationStatus(for: .event))
        case .automationNotes: return NotesWriter.automationState
        case .contacts: return Self.state(CNContactStore.authorizationStatus(for: .contacts))
        case .accessibility, .screenRecording: return .unknown
        }
    }

    /// The system prompt where one exists (first use), else the Privacy pane.
    func request(_ permission: Permission) async -> PermissionState {
        let current = state(of: permission)
        switch permission {
        case .reminders where current == .notDetermined:
            _ = try? await EKEventStore().requestFullAccessToReminders()
        case .calendar where current == .notDetermined:
            _ = try? await EKEventStore().requestWriteOnlyAccessToEvents()
        case .contacts where current == .notDetermined:
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .automationNotes where current == .notDetermined:
            NotesWriter.run(NotesScript.probe)
        case .reminders, .calendar, .contacts, .automationNotes:
            Self.openPrivacyPane(for: permission)
        case .accessibility, .screenRecording:
            break
        }
        return state(of: permission)
    }

    static func state(_ status: EKAuthorizationStatus) -> PermissionState {
        switch status {
        case .fullAccess, .writeOnly: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        default: return .unknown
        }
    }

    static func state(_ status: CNAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        default: return .unknown
        }
    }

    static func privacyPaneURL(for permission: Permission) -> URL? {
        let anchor: String
        switch permission {
        case .reminders: anchor = "Privacy_Reminders"
        case .calendar: anchor = "Privacy_Calendars"
        case .automationNotes: anchor = "Privacy_Automation"
        case .contacts: anchor = "Privacy_Contacts"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    private static func openPrivacyPane(for permission: Permission) {
        guard let url = privacyPaneURL(for: permission) else { return }
        NSWorkspace.shared.open(url)
    }
}
