import SwiftUI

@main
struct SkillManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = SkillStore()
    @StateObject private var chatSessions = ChatSessionStore()
    @StateObject private var updateController = UpdateController()

    var body: some Scene {
        WindowGroup("Skill Manager") {
            ContentView()
                .environmentObject(store)
                .environmentObject(chatSessions)
                .environmentObject(updateController)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    appDelegate.updateController = updateController
                    updateController.startAutomaticChecks()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updateController.checkForUpdates() }
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(updateController)
        }
    }
}

/// Ensures the app shows a window and menu bar when launched as a bare
/// binary during development (swift run), not just from an .app bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var updateController: UpdateController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        SkillTrial.pruneStale()
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateController?.stopAutomaticChecks()
    }
}
