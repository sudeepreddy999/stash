import AppKit
import Combine
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// Root state graph. Owns every long-lived service and wires them together.
///
/// - `store`      — on-disk clipboard history
/// - `monitor`    — polls NSPasteboard and inserts into `store`
/// - `popup`      — floating cursor popup
/// - `hotkey`     — Carbon global shortcut → `popup.toggle()`
@MainActor
final class AppState: ObservableObject {
    let store: ClipboardStore
    let monitor: ClipboardMonitor
    let popup: PopupController
    private let hotkey = HotkeyManager()

    /// Set by `AppDelegate` after `StatusItemController` is created.
    /// The menu-bar list uses this to route tap-to-paste through the same
    /// focus-restoration flow as the cursor popup.
    weak var statusItemController: StatusItemController?

    @Published var currentHotkey: Hotkey {
        didSet {
            persistHotkey()
            registerHotkey()
        }
    }

    /// `true` when the system refused the current shortcut (usually because
    /// another app owns it). Settings shows a warning so the user knows why
    /// nothing happens and can pick a different preset.
    @Published private(set) var hotkeyRegistrationFailed = false

    /// Mirrors `SMAppService.mainApp` so Settings can bind a Toggle to it.
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Stash: failed to update login item: \(error)")
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private static let hotkeyDefaultsKey = "stash.hotkey"
    private static let axAlertShownKey = "stash.axAlertShown"

    /// Retained so the settings window survives being closed and reopened.
    private var settingsWindow: NSWindow?
    private var settingsWindowDelegate: SettingsWindowDelegate?

    init() {
        let store = ClipboardStore()
        let monitor = ClipboardMonitor(store: store)
        self.store = store
        self.monitor = monitor
        self.popup = PopupController(store: store, monitor: monitor)
        self.currentHotkey = Self.loadHotkey()

        hotkey.onTrigger = { [weak self] in
            self?.popup.toggle()
        }
    }

    func start() {
        monitor.start()
        registerHotkey()
        requestAccessibilityIfNeeded()
    }

    private func registerHotkey() {
        hotkeyRegistrationFailed = !hotkey.register(currentHotkey)
    }

    /// Shared destructive-action guard for the menu-bar menu and Settings.
    func confirmAndClearHistory() {
        let count = store.items.count
        guard count > 0 else { return }

        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "This removes all \(count) stashed clip\(count == 1 ? "" : "s"), including pinned ones. This can't be undone."
        alert.alertStyle = .warning
        let clear = alert.addButton(withTitle: "Clear History")
        clear.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            store.clear()
        }
    }

    // MARK: - Accessibility

    /// Called from `AppDelegate.applicationDidFinishLaunching`.
    ///
    /// No-op once Accessibility is granted (`AXIsProcessTrusted()` is a cheap
    /// check with no UI). If it isn't granted, we ask exactly once ever:
    /// (a) the system's standard "add to Accessibility" dialog via
    /// `AXIsProcessTrustedWithOptions`, and (b) our own `NSAlert` explaining
    /// *why*, with an "Open System Settings" deep link. Declining auto-paste is
    /// a valid choice and shouldn't be re-litigated on every launch — a
    /// once-only flag guards the whole ask (both prompts), and Settings keeps a
    /// re-entry point.
    func requestAccessibilityIfNeeded() {
        // Already granted — nothing to ask for.
        if AXIsProcessTrusted() { return }

        // Ask at most once. The guard must sit *above* the system prompt too,
        // or `AXIsProcessTrustedWithOptions(prompt:)` re-pops the system dialog
        // on every launch while access stays ungranted.
        guard !UserDefaults.standard.bool(forKey: Self.axAlertShownKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.axAlertShownKey)

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.showAccessibilityAlert()
        }
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Enable auto-paste for Stash"
        alert.informativeText = """
        Stash needs Accessibility permission to press ⌘V for you after you pick a clip. \
        Without it, clips still land on your system clipboard — you'll just paste manually.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational

        // Ensure the alert appears above whatever's on screen.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    // MARK: - Settings window

    /// Show (or bring to front) the Settings window using a plain `NSWindow`.
    /// This is more reliable inside an accessory (`LSUIElement`) app than
    /// SwiftUI's `openSettings` environment key, which sometimes silently
    /// no-ops when there is no menu bar to route through.
    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)

        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView()
                .environmentObject(self)
                .environmentObject(store)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Stash Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 460, height: 480))
        window.center()
        window.isReleasedWhenClosed = false

        let delegate = SettingsWindowDelegate { [weak self] in
            // Keep window alive for reuse; nothing to do here yet.
            _ = self
        }
        settingsWindowDelegate = delegate
        window.delegate = delegate

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Hotkey persistence

    private func persistHotkey() {
        if let data = try? JSONEncoder().encode(currentHotkey) {
            UserDefaults.standard.set(data, forKey: Self.hotkeyDefaultsKey)
        }
    }

    private static func loadHotkey() -> Hotkey {
        if let data = UserDefaults.standard.data(forKey: hotkeyDefaultsKey),
           let hk = try? JSONDecoder().decode(Hotkey.self, from: data) {
            return hk
        }
        return .default
    }
}

/// Trivial NSWindowDelegate that fires a callback when the settings window
/// closes. Kept outside `AppState` so the class doesn't need `NSWindowDelegate`
/// conformance (which would drag AppKit into every user of `AppState`).
@MainActor
final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}
