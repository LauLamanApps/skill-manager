import SwiftUI

@main
struct SkillManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = SkillStore()

    var body: some Scene {
        WindowGroup("Skill Manager") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 560)
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

/// Ensures the app shows a window and menu bar when launched as a bare
/// binary during development (swift run), not just from an .app bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
