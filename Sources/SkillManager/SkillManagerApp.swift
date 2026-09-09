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
            // The stock Settings scene draws its own preferences-style chrome,
            // which insets the sidebar differently from the main window. Settings
            // is a plain Window instead, so this re-supplies the menu item.
            CommandGroup(replacing: .appSettings) {
                OpenSettingsButton()
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updateController.checkForUpdates(manual: true) }
                }
            }
        }

        // Keyed by id, so each skill gets exactly one window: opening a skill
        // that is already open brings its window forward instead of duplicating.
        WindowGroup("Skill", id: SkillWindow.id, for: Skill.ID.self) { $skillID in
            SkillWindowView(skillID: skillID)
                .environmentObject(store)
                .environmentObject(chatSessions)
                // Wide enough that the sidebar, the editor and the chat
                // panel all fit without squeezing the toolbar into overflow.
                .frame(minWidth: 960, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 800)

        Window("Settings", id: SettingsWindow.id) {
            SettingsView()
                .environmentObject(store)
                .environmentObject(updateController)
                .frame(minWidth: 780, minHeight: 480)
        }
        .defaultSize(width: 820, height: 540)
    }
}

enum SettingsWindow {
    static let id = "settings"
}

/// `openWindow` is only reachable from a View, so the Settings menu item is one.
private struct OpenSettingsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") { openWindow(id: SettingsWindow.id) }
            .keyboardShortcut(",", modifiers: .command)
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
