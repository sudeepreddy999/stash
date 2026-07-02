import AppKit
import Foundation

@MainActor
final class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private var suppressCount = 0

    unowned let store: ClipboardStore

    init(store: ClipboardStore) {
        self.store = store
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.check() }
        }
        // A little slack lets the system coalesce wakeups (energy), and
        // `.common` keeps polling alive while menus/drags run their tracking
        // loops — a default-mode timer silently pauses there, dropping any
        // copy made in that window.
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Call before writing to the pasteboard from within the app so we don't
    /// re-capture our own paste as a new history entry.
    func suppressNext() {
        suppressCount += 1
    }

    private func check() {
        let cc = pasteboard.changeCount
        guard cc != lastChangeCount else { return }
        lastChangeCount = cc
        if suppressCount > 0 {
            suppressCount -= 1
            return
        }
        // De-facto standard markers (nspasteboard.org): password managers and
        // other apps flag sensitive or ephemeral content so clipboard
        // managers leave it out of history.
        let skip: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
        if pasteboard.types?.contains(where: { skip.contains($0.rawValue) }) == true {
            return
        }
        if let item = ClipItem.fromPasteboard(pasteboard) {
            store.add(item)
        }
    }
}
