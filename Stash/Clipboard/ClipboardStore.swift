import Foundation
import Combine

/// On-disk history of clipboard items.
///
/// The manifest (`history.json`) holds metadata only; image bitmaps live as
/// individual files managed by `ClipStorage`, so saves stay small and no
/// bitmap is ever resident in memory just because it's in history.
/// Emits `capturePulse` on every successful new capture — the menubar icon
/// listens to this to bounce.
@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var capturePulse: Int = 0

    /// User-adjustable history cap (Settings). Pinned items never count
    /// against it and are never trimmed.
    @Published private(set) var maxItems: Int

    /// How many recent clips the cursor popup shows. Capped at 9 so every
    /// slot keeps a single-keystroke shortcut (`1`–`9`); beyond that you'd
    /// need scrolling, which is the menu-bar list's job, not the popup's.
    @Published private(set) var popupLimit: Int

    static let popupLimitRange = 5...9

    private static let maxItemsKey = "stash.maxItems"
    private static let popupLimitKey = "stash.popupLimit"

    init() {
        let storedMax = UserDefaults.standard.integer(forKey: Self.maxItemsKey)
        self.maxItems = storedMax > 0 ? storedMax : 100

        let storedPopup = UserDefaults.standard.integer(forKey: Self.popupLimitKey)
        self.popupLimit = Self.popupLimitRange.contains(storedPopup) ? storedPopup : 5

        load()
    }

    var pinnedItems: [ClipItem] { items.filter(\.isPinned) }
    var recentItems: [ClipItem] { items.filter { !$0.isPinned } }

    func setMaxItems(_ n: Int) {
        guard n > 0, n != maxItems else { return }
        maxItems = n
        UserDefaults.standard.set(n, forKey: Self.maxItemsKey)
        trimOverflow()
        save()
    }

    func setPopupLimit(_ n: Int) {
        let clamped = min(max(Self.popupLimitRange.lowerBound, n), Self.popupLimitRange.upperBound)
        guard clamped != popupLimit else { return }
        popupLimit = clamped
        UserDefaults.standard.set(clamped, forKey: Self.popupLimitKey)
    }

    func add(_ item: ClipItem) {
        // Re-copying something already in history moves it to the top
        // instead of creating a duplicate entry (keeping its pin state).
        if let existing = items.firstIndex(where: { isSameContent($0, item) }) {
            discardPayload(of: item)
            if existing > 0 {
                items.insert(items.remove(at: existing), at: 0)
                save()
            }
            capturePulse &+= 1
            return
        }

        items.insert(item, at: 0)
        trimOverflow()
        capturePulse &+= 1
        save()
    }

    func togglePin(_ item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx] = items[idx].withPinned(!items[idx].isPinned)
        save()
    }

    /// Drop the oldest *unpinned* items until the cap is respected.
    private func trimOverflow() {
        var unpinnedCount = items.lazy.filter { !$0.isPinned }.count
        while unpinnedCount > maxItems,
              let idx = items.lastIndex(where: { !$0.isPinned }) {
            discardPayload(of: items.remove(at: idx))
            unpinnedCount -= 1
        }
    }

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        discardPayload(of: item)
        save()
    }

    func clear() {
        let removed = items
        items.removeAll()
        removed.forEach(discardPayload)
        save()
    }

    /// Delete the on-disk bitmap belonging to an item that is leaving (or
    /// never entering) history.
    private func discardPayload(of item: ClipItem) {
        guard item.kind == .image else { return }
        ClipStorage.deleteImage(for: item.id)
    }

    private func isSameContent(_ a: ClipItem, _ b: ClipItem) -> Bool {
        guard a.kind == b.kind else { return false }
        switch a.kind {
        case .text: return a.text == b.text
        case .file: return a.filePaths == b.filePaths
        case .image: return a.imageHash != nil && a.imageHash == b.imageHash
        }
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: ClipStorage.historyURL, options: .atomic)
        } catch {
            NSLog("Stash: failed to save history: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: ClipStorage.historyURL),
              let decoded = try? JSONDecoder().decode([ClipItem].self, from: data)
        else { return }

        // Migrate legacy entries that inlined image bytes in the JSON: move
        // the bitmap into ClipStorage and keep only metadata. If a file
        // write fails the bytes stay inline so nothing is lost.
        var migrated = false
        items = decoded.map { item in
            guard item.kind == .image, let legacy = item.legacyImageData else { return item }
            guard ClipStorage.writeImage(legacy, for: item.id) else { return item }
            migrated = true
            return ClipItem(
                id: item.id,
                createdAt: item.createdAt,
                kind: .image,
                imageSize: ClipStorage.pixelSize(of: legacy),
                imageHash: ClipItem.pngHash(of: legacy)
            )
        }

        ClipStorage.pruneImages(keeping: Set(items.lazy.filter { $0.kind == .image }.map(\.id)))
        if migrated { save() }
    }
}
