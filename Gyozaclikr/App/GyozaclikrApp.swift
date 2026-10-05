import SwiftUI

/// A menu-bar agent: no Dock icon, no main window. The coordinator owns the
/// status item, the box and every module; the Settings scene is the only
/// SwiftUI window.
@main
struct GyozaclikrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(model: delegate.coordinator.settingsModel)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var coordinator = Coordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nothing to activate: the status item and the hot key are live from init.
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        coordinator.refreshPermissions()
    }
}
