import AppKit
import Combine
import SwiftUI

/// Owns the real `NSStatusItem` and the `NSPopover` that shows the history.
///
/// We used to rely on SwiftUI's `MenuBarExtra`, but its label is often
/// rendered as a snapshot — SwiftUI animations (`.symbolEffect`, scale) never
/// made it to screen. Managing the status item ourselves lets us:
///
/// - drive a live Core Animation hop on `store.capturePulse`
/// - present the SwiftUI `MenuBarContent` inside an `NSPopover`
/// - later swap the SF Symbol for a pixel-art `NSHostingView` (see the
///   `MenuBarIcon` extension point in `DOCS.md`)
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var cancellables = Set<AnyCancellable>()

    /// Event monitors installed while the popover is open.
    ///
    /// - `escKeyMonitor` closes on Escape — `NSPopover` doesn't handle it when
    ///   the content is SwiftUI.
    /// - `outsideClickMonitor` closes on clicks outside the popover. We drive
    ///   this ourselves rather than trusting `.transient`, whose outside-click
    ///   dismissal is tied to an app activation *transition* and stops working
    ///   after an Esc-triggered close (which leaves the app already active).
    private var escKeyMonitor: Any?
    private var outsideClickMonitor: Any?

    /// Captured when the popover opens so `paste(_:)` can restore focus to
    /// whatever the user was doing before clicking the menu bar.
    private var previousApp: NSRunningApplication?

    unowned let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        configureButton()
        configurePopover()
        subscribeToStore()
    }

    // MARK: - Setup

    private func configureButton() {
        guard let button = statusItem.button else { return }

        let image = NSImage(
            systemSymbolName: "square.stack.3d.up.fill",
            accessibilityDescription: "Stash"
        )
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.wantsLayer = true

        button.target = self
        button.action = #selector(togglePopover(_:))
    }

    private func configurePopover() {
        let root = MenuBarContent()
            .environmentObject(appState)
            .environmentObject(appState.store)

        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]

        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 320, height: 380)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    private func subscribeToStore() {
        appState.store.$capturePulse
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.animateBounce()
            }
            .store(in: &cancellables)
    }

    // MARK: - Popover

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installDismissMonitors()
    }

    private func installDismissMonitors() {
        removeDismissMonitors()

        // Escape closes.
        escKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // 53 = Escape
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self.popover.performClose(nil) }
            return nil
        }

        // Clicks outside the popover close it. Global monitors only see events
        // headed for *other* apps, so in-popover clicks don't reach here; the
        // frame hit-test is a safety net for the accessory-app case where the
        // popover can be shown while our app isn't active.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self else { return }
                if let frame = self.popover.contentViewController?.view.window?.frame,
                   frame.contains(location) { return }
                self.popover.performClose(nil)
            }
        }
    }

    private func removeDismissMonitors() {
        if let monitor = escKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escKeyMonitor = nil
        }
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// Called from `MenuBarContent` when the user taps a row.
    /// Closes the popover, hands focus back to the app that was frontmost
    /// when the menu bar was clicked, and posts ⌘V.
    func paste(_ item: ClipItem) {
        let prev = previousApp
        previousApp = nil
        popover.performClose(nil)
        PasteEngine.paste(item, restoringFocusTo: prev, monitor: appState.monitor)
    }

    // NSPopoverDelegate — reset the captured focus target if the user
    // dismisses the popover without picking anything.
    func popoverDidClose(_ notification: Notification) {
        previousApp = nil
        removeDismissMonitors()
    }

    // MARK: - Icon animation

    /// Little hop + wiggle whenever a new clip lands.
    ///
    /// Uses translation.y (independent of anchor point, so it works on the
    /// status-bar layer without shifting) plus a subtle rotation for
    /// character. Duration is short enough that rapid copies chain nicely.
    private func animateBounce() {
        guard let button = statusItem.button, let layer = button.layer else { return }

        let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        hop.values = [0, -3, 0, -1.5, 0]
        hop.keyTimes = [0, 0.3, 0.55, 0.75, 1.0]
        hop.duration = 0.45
        hop.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeIn),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeIn)
        ]

        let wiggle = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        wiggle.values = [0.0, -0.14, 0.12, -0.06, 0.0]
        wiggle.keyTimes = [0, 0.25, 0.5, 0.75, 1.0]
        wiggle.duration = 0.45

        let group = CAAnimationGroup()
        group.animations = [hop, wiggle]
        group.duration = 0.45
        group.isRemovedOnCompletion = true

        layer.add(group, forKey: "capturePulse")
    }
}
