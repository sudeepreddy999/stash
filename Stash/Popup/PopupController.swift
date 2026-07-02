import AppKit
import Combine
import SwiftUI

/// Owns the floating popup panel that appears near the cursor.
///
/// **Focus dance.** The panel must be *key* to receive keyboard input, but
/// we also need the previously-active app to come back so simulated ⌘V lands
/// in its text field. On `show` we remember `NSWorkspace.frontmostApplication`,
/// then `NSApp.activate`. On paste we re-activate the previous app *before*
/// posting the ⌘V event.
///
/// Key events are handled through an `NSEvent` local monitor (not SwiftUI's
/// `.onKeyPress`) so that arrows/enter/1-5 always work regardless of which
/// SwiftUI element is focused.
///
/// **Stable list.** The panel shows only the top `initialLimit` items.
@MainActor
final class PopupController: ObservableObject {
    @Published var selection: Int = 0

    /// Whether the currently-selected clip is expanded to fill the popup
    /// (driven by the right/left arrows). Mutations are wrapped in
    /// `withAnimation` so the SwiftUI card grows/shrinks smoothly.
    @Published private(set) var isExpanded = false

    /// Bumped on every `show()` so the popup can replay the blob entrance
    /// animation each time it appears. The hosting view is reused across
    /// show/hide, so `onAppear` alone only fires once.
    @Published private(set) var revealToken = 0

    private var panel: KeyablePanel?
    private var previousApp: NSRunningApplication?
    private var outsideClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var storeSubscription: AnyCancellable?

    // Geometry lives in `PopupMetrics` (shared with the SwiftUI layout so
    // the panel frame always matches the rendered content).
    private let initialLimit = 5

    unowned let store: ClipboardStore
    unowned let monitor: ClipboardMonitor

    init(store: ClipboardStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Pinned clips float to the top — same ordering the menu-bar list uses —
    /// so a pinned item is always reachable from the popup regardless of how
    /// much has been copied since.
    var visibleItems: [ClipItem] {
        Array((store.pinnedItems + store.recentItems).prefix(initialLimit))
    }

    // MARK: - Show / hide

    func toggle() {
        isVisible ? hide() : show()
    }

    /// `focusTarget` overrides where auto-paste should return focus. Callers
    /// that already know the user's "real" app (the menu-bar popover captures
    /// it when the status item is clicked) pass it here; otherwise we take
    /// the current frontmost app — unless that's Stash itself, which would
    /// make the eventual ⌘V a no-op.
    func show(returningFocusTo focusTarget: NSRunningApplication? = nil) {
        if let focusTarget {
            previousApp = focusTarget
        } else if let front = NSWorkspace.shared.frontmostApplication,
                  front.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }
        selection = 0
        isExpanded = false
        revealToken &+= 1

        if panel == nil { panel = buildPanel() }
        guard let panel else { return }

        panel.setFrame(computeFrame(), display: false)
        panel.alphaValue = 0

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Assert front/key even if the app didn't fully activate (accessory
        // apps lose the activation race after a paste reactivates the previous
        // app). Without this the panel can appear while our app is inactive,
        // which lets clicks on it leak to the outside-click monitor.
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }

        installMonitors()
        subscribeStore()
    }

    /// `restoreFocus` re-activates the app that was frontmost before the
    /// popup opened. Pass `false` when the dismissal was caused by the user
    /// clicking into some *other* app — re-activating the old app then would
    /// steal focus from the one they just clicked.
    func hide(restoreFocus: Bool = true) {
        removeMonitors()
        storeSubscription = nil
        let prev = previousApp
        previousApp = nil

        if let panel, panel.isVisible {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.10
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        }
        if restoreFocus {
            prev?.activate(options: [])
        }
    }

    // MARK: - Selection & paste

    func moveSelection(by delta: Int) {
        let count = visibleItems.count
        guard count > 0 else { return }
        selection = min(max(0, selection + delta), count - 1)
    }

    /// Blow the selected clip up to fill the whole popup so its full contents
    /// are readable. No-op when there's nothing selected or it's already open.
    func expandSelected() {
        guard !isExpanded, selection >= 0, selection < visibleItems.count else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            isExpanded = true
        }
    }

    func collapse() {
        guard isExpanded else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            isExpanded = false
        }
    }

    func hover(_ index: Int) {
        guard index >= 0, index < visibleItems.count else { return }
        selection = index
    }

    func pasteSelected() {
        paste(at: selection)
    }

    /// Remove the selected clip without dismissing — the store subscription
    /// reflows and resizes the panel.
    func deleteSelected() {
        let items = visibleItems
        guard selection >= 0, selection < items.count else { return }
        store.remove(items[selection])
    }

    func togglePinSelected() {
        togglePin(at: selection)
    }

    /// Pin/unpin a clip without dismissing. Pinning floats the item to the top
    /// (via `visibleItems`), so we follow it to its new index to keep the
    /// selection glued to the clip the user acted on. The shared store persists
    /// and republishes, so the menu-bar list reflects the change immediately.
    func togglePin(at index: Int) {
        let items = visibleItems
        guard index >= 0, index < items.count else { return }
        let target = items[index]
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            store.togglePin(target)
        }
        if let newIndex = visibleItems.firstIndex(where: { $0.id == target.id }) {
            selection = newIndex
        }
    }

    func paste(at index: Int) {
        let items = visibleItems
        guard index >= 0, index < items.count else { return }
        paste(items[index])
    }

    private func paste(_ item: ClipItem) {
        removeMonitors()
        storeSubscription = nil
        panel?.orderOut(nil)

        let prev = previousApp
        previousApp = nil
        PasteEngine.paste(item, restoringFocusTo: prev, monitor: monitor)
    }

    // MARK: - Panel construction & sizing

    private func buildPanel() -> KeyablePanel {
        let root = PopupView(controller: self).environmentObject(store)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: PopupMetrics.panelWidth, height: computedHeight())

        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: PopupMetrics.panelWidth, height: computedHeight()),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.hasShadow = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .utilityWindow
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = hosting
        return p
    }

    private func computedHeight() -> CGFloat {
        PopupMetrics.panelHeight(rows: visibleItems.count)
    }

    private func computeFrame() -> NSRect {
        let height = computedHeight()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main!
        let visible = screen.visibleFrame

        let width = PopupMetrics.panelWidth
        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - height - 12)
        if origin.x + width > visible.maxX - 8 { origin.x = visible.maxX - width - 8 }
        if origin.x < visible.minX + 8 { origin.x = visible.minX + 8 }
        if origin.y < visible.minY + 8 { origin.y = mouse.y + 20 }
        if origin.y + height > visible.maxY - 8 { origin.y = visible.maxY - height - 8 }
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }

    /// Animate the panel to fit the current visible item count. Anchors on the
    /// top-left so the popup grows *downward* (feels like more content is
    /// unfolding underneath, not pushing the header around).
    private func resizePanel(animated: Bool) {
        guard let panel else { return }
        let newHeight = computedHeight()
        let old = panel.frame
        let deltaY = old.height - newHeight
        let newFrame = NSRect(x: old.origin.x,
                              y: old.origin.y + deltaY,
                              width: old.width,
                              height: newHeight)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(newFrame, display: true)
            }
        } else {
            panel.setFrame(newFrame, display: true)
        }
    }

    // MARK: - Store subscription (so store changes while popup open reflow)

    private func subscribeStore() {
        storeSubscription = store.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }

                if self.isExpanded {
                    // The clip being read shifted out from under us (or the
                    // list emptied) — drop back to the list rather than show a
                    // different clip in the expanded card.
                    if self.selection >= self.visibleItems.count {
                        self.collapse()
                    }
                } else {
                    self.selection = min(self.selection, max(0, self.visibleItems.count - 1))
                }
                self.resizePanel(animated: true)
            }
    }

    // MARK: - Event monitoring

    private func installMonitors() {
        removeMonitors()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            // Screen-coordinate mouse location, captured now (closest to the
            // click) rather than inside the async hop.
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self, let panel = self.panel else { return }
                // Clicks inside the popup must never dismiss it. Global monitors
                // normally only see events for *other* apps, but when the popup
                // is shown while our accessory app isn't active, clicks on the
                // panel (e.g. grabbing the header to drag) surface here too — and
                // dismissing on those is the drag-gets-cancelled bug.
                if panel.frame.contains(location) { return }
                // The click already went to another app — don't fight it for
                // focus by re-activating the app the popup was opened over.
                self.hide(restoreFocus: false)
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handleKey(event) }
            return handled ? nil : event
        }
    }

    private func removeMonitors() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
        if let m = localKeyMonitor {
            NSEvent.removeMonitor(m)
            localKeyMonitor = nil
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // esc — collapse first, then dismiss
            if isExpanded { collapse() } else { hide() }
            return true
        case 36, 76: // return — paste works in either state
            pasteSelected(); return true
        case 124: // right arrow — expand the selection
            expandSelected(); return true
        case 123: // left arrow — back to the list
            collapse(); return true
        case 125: // down
            if !isExpanded { moveSelection(by: 1) }
            return true
        case 126: // up
            if !isExpanded { moveSelection(by: -1) }
            return true
        case 51: // delete — only meaningful in the list
            if !isExpanded { deleteSelected() }
            return true
        default:
            // Bare keys only — ⌘1, ⌘P etc. should keep their normal meaning.
            let mods = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(.numericPad)
            guard mods.isEmpty,
                  let ch = event.charactersIgnoringModifiers?.first else { return false }
            // P pins/unpins the current selection (works in either state).
            if ch == "p" || ch == "P" {
                togglePinSelected()
                return true
            }
            if let d = ch.wholeNumberValue, (1...initialLimit).contains(d) {
                paste(at: d - 1)
                return true
            }
            return false
        }
    }
}
