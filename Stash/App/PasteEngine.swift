import AppKit
import ApplicationServices

/// Shared paste flow used by both the cursor popup and the menu-bar list.
///
/// The two call sites both need the same three-step dance:
/// 1. Suppress the clipboard monitor's next capture (so the item we're about
///    to write to the pasteboard doesn't come straight back into history).
/// 2. Write the item to the system pasteboard.
/// 3. Restore focus to whichever app was frontmost *before* Stash took over,
///    then synthesize a `⌘V` press so the paste lands where the user was
///    typing.
///
/// Requires Accessibility permission for step 3 (the `CGEvent.post`).
enum PasteEngine {
    static func simulatePasteShortcut() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    @MainActor
    static func paste(
        _ item: ClipItem,
        restoringFocusTo previousApp: NSRunningApplication?,
        monitor: ClipboardMonitor
    ) {
        monitor.suppressNext()
        item.writeToPasteboard()
        previousApp?.activate(options: [])

        // Without Accessibility the synthetic ⌘V would be silently dropped —
        // the clip is on the pasteboard and focus is restored, so the user
        // just presses ⌘V themselves.
        guard AXIsProcessTrusted() else { return }

        if let previousApp {
            waitForActivation(of: previousApp, attemptsLeft: 20)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                simulatePasteShortcut()
            }
        }
    }

    /// Post ⌘V once the target app is actually frontmost instead of after a
    /// fixed delay — slow apps used to receive the event too early (or a
    /// different app received it). Gives up after ~1 s and posts anyway so a
    /// hung target can't swallow the paste forever.
    @MainActor
    private static func waitForActivation(of app: NSRunningApplication, attemptsLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if app.isActive || app.isTerminated || attemptsLeft <= 0 {
                simulatePasteShortcut()
            } else {
                waitForActivation(of: app, attemptsLeft: attemptsLeft - 1)
            }
        }
    }
}
