import AppKit
import SwiftUI

/// The Settings window, opened by the app itself. A menu-bar agent has no
/// key window for SwiftUI's own settings command to hang off, so the
/// coordinator shows this one directly.
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(model: SettingsModel, tab: SettingsTab = .general) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model, tab: tab))
            let window = NSWindow(contentViewController: host)
            window.title = "Gyozaclikr Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: Theme.Settings.width, height: Theme.Settings.height))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
