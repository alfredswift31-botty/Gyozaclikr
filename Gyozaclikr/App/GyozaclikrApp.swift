import SwiftUI

/// The scaffold entry point: a menu-bar item that proves the project builds,
/// signs and launches. The real coordinator (capture → box → router →
/// engine → actions) replaces the body once the modules land.
@main
struct GyozaclikrApp: App {
    var body: some Scene {
        MenuBarExtra("Gyozaclikr", systemImage: "cursorarrow.rays") {
            Text("Gyozaclikr \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(Theme.Typeface.meta)
                .foregroundStyle(Theme.inkSecondary)
            Divider()
            Button("Quit Gyozaclikr") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
