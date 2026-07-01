import SwiftUI

/// Entry point. The menu bar UI is *not* declared here anymore — it's
/// created imperatively by `StatusItemController` (spawned from
/// `AppDelegate.applicationDidFinishLaunching`). See `MenuBar/StatusItemController.swift`.
///
/// The Settings scene stays as a SwiftUI fallback, but `AppState.openSettings()`
/// prefers a manually-managed `NSWindow` for reliability inside an accessory
/// app (`Settings`-scene's `openSettings` environment key is flaky when there
/// is no app menu bar).
@main
struct StashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }
    }
}
