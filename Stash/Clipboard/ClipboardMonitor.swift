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
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.check() }
        }
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
        if let item = ClipItem.fromPasteboard(pasteboard) {
            store.add(item)
        }
    }
}
