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

    /// Bumped on every `show()` so the popup can replay the blob entrance
    /// animation each time it appears. The hosting view is reused across
    /// show/hide, so `onAppear` alone only fires once.
    @Published private(set) var revealToken = 0

    private var panel: KeyablePanel?
    private var previousApp: NSRunningApplication?
    private var outsideClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var storeSubscription: AnyCancellable?

    // Sizing — tuned for the blob layout (header + 5 item blobs).
    private let panelWidth: CGFloat = 400
    private let headerBlockHeight: CGFloat = 42     // header blob + spacing below
    private let rowViewportHeight: CGFloat = 80     // one visible row slot in the viewport (includes inter-row spacing)
    private let panelChrome: CGFloat = 20           // 10 top + 10 bottom padding
    private let emptyHeight: CGFloat = 210

    private let initialLimit = 5

    unowned let store: ClipboardStore
    unowned let monitor: ClipboardMonitor

    init(store: ClipboardStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    var visibleItems: [ClipItem] {
        Array(store.items.prefix(initialLimit))
    }

    var listViewportHeight: CGFloat {
        guard !store.items.isEmpty else { return 0 }
        let rows = min(CGFloat(visibleItems.count), CGFloat(initialLimit))
        return rows * rowViewportHeight
    }

    // MARK: - Show / hide

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        selection = 0
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

    func hide() {
        removeMonitors()
        storeSubscription = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        previousApp?.activate(options: [])
        previousApp = nil
    }

    // MARK: - Selection & paste

    func moveSelection(by delta: Int) {
        let count = visibleItems.count
        guard count > 0 else { return }
        selection = min(max(0, selection + delta), count - 1)
    }

    func hover(_ index: Int) {
        guard index >= 0, index < visibleItems.count else { return }
        selection = index
    }

    func pasteSelected() {
        paste(at: selection)
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
        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: computedHeight())

        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: computedHeight()),
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
        if store.items.isEmpty { return emptyHeight }
        let rows = min(CGFloat(visibleItems.count), CGFloat(initialLimit))
        return headerBlockHeight + rows * rowViewportHeight + panelChrome
    }

    private func computeFrame() -> NSRect {
        let height = computedHeight()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main!
        let visible = screen.visibleFrame

        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - height - 12)
        if origin.x + panelWidth > visible.maxX - 8 { origin.x = visible.maxX - panelWidth - 8 }
        if origin.x < visible.minX + 8 { origin.x = visible.minX + 8 }
        if origin.y < visible.minY + 8 { origin.y = mouse.y + 20 }
        if origin.y + height > visible.maxY - 8 { origin.y = visible.maxY - height - 8 }
        return NSRect(origin: origin, size: NSSize(width: panelWidth, height: height))
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

                self.selection = min(self.selection, max(0, self.visibleItems.count - 1))
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
                self.hide()
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
        case 53:
            hide(); return true
        case 36, 76:
            pasteSelected(); return true
        case 125:
            moveSelection(by: 1); return true
        case 126:
            moveSelection(by: -1); return true
        default:
            if let ch = event.charactersIgnoringModifiers?.first,
               let d = ch.wholeNumberValue,
               (1...initialLimit).contains(d) {
                paste(at: d - 1)
                return true
            }
            return false
        }
    }
}
