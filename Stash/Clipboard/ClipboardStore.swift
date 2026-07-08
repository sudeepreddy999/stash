import Combine
import Foundation
import SwiftData

/// Clipboard history, backed by SwiftData.
///
/// Rows live in a `ClipRecord` store; image bitmaps stay on disk as individual
/// PNG files (`ClipStorage`). This object is the single writer *and* the
/// SwiftUI-facing façade: it republishes the history as lightweight value-type
/// `ClipItem`s so every view and controller keeps its existing API.
///
/// Why SwiftData over the old `history.json` manifest: a capture now writes one
/// row incrementally instead of re-encoding and rewriting the entire history on
/// every copy, and time-based retention is a cheap predicate delete.
///
/// Memory: bitmaps never sit on the heap — they're read from disk and
/// downsampled only when a thumbnail is actually shown. The row count is
/// bounded by the retention window when one is set ("Forever" keeps everything).
///
/// Emits `capturePulse` on every successful new capture — the menubar icon
/// listens to this to bounce.
@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var capturePulse: Int = 0

    /// How many recent clips the cursor popup shows. Capped at 9 so every
    /// slot keeps a single-keystroke shortcut (`1`–`9`); beyond that you'd
    /// need scrolling, which is the menu-bar list's job, not the popup's.
    @Published private(set) var popupLimit: Int

    /// Auto-delete clips older than this many days. `0` keeps them forever.
    /// Pinned clips are always kept, regardless of age.
    @Published private(set) var retentionDays: Int

    static let popupLimitRange = 5...9

    private static let popupLimitKey = "stash.popupLimit"
    private static let retentionDaysKey = "stash.retentionDays"
    private static let didMigrateKey = "stash.didMigrateToSwiftData"

    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    private var retentionTimer: Timer?

    init() {
        let defaults = UserDefaults.standard

        let storedPopup = defaults.integer(forKey: Self.popupLimitKey)
        self.popupLimit = Self.popupLimitRange.contains(storedPopup) ? storedPopup : 5

        self.retentionDays = max(0, defaults.integer(forKey: Self.retentionDaysKey))

        // Open the SwiftData store next to the images folder. If it can't be
        // opened (disk/schema failure), fall back to an in-memory store so the
        // app still runs — history just won't persist across launches.
        do {
            let config = ModelConfiguration(url: ClipStorage.storeURL)
            self.container = try ModelContainer(for: ClipRecord.self, configurations: config)
        } catch {
            NSLog("Stash: failed to open history store, using in-memory: \(error)")
            self.container = try! ModelContainer(
                for: ClipRecord.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }

        cleanUpLegacyStoreIfNeeded()
        refresh()
        pruneExpired()
        startRetentionTimer()
    }

    var pinnedItems: [ClipItem] { items.filter(\.isPinned) }
    var recentItems: [ClipItem] { items.filter { !$0.isPinned } }

    // MARK: - Settings

    func setPopupLimit(_ n: Int) {
        let clamped = min(max(Self.popupLimitRange.lowerBound, n), Self.popupLimitRange.upperBound)
        guard clamped != popupLimit else { return }
        popupLimit = clamped
        UserDefaults.standard.set(clamped, forKey: Self.popupLimitKey)
    }

    func setRetentionDays(_ n: Int) {
        let value = max(0, n)
        guard value != retentionDays else { return }
        retentionDays = value
        UserDefaults.standard.set(value, forKey: Self.retentionDaysKey)
        pruneExpired()
    }

    // MARK: - Mutations

    func add(_ item: ClipItem) {
        // Re-copying something already in history floats it back to the top
        // instead of creating a duplicate entry (keeping its pin state).
        if let existing = items.first(where: { isSameContent($0, item) }) {
            discardPayload(of: item)
            record(withID: existing.id)?.createdAt = Date()
            try? context.save()
            refresh()
            capturePulse &+= 1
            return
        }

        context.insert(makeRecord(from: item))
        deleteExpiredRecords()
        try? context.save()
        refresh()
        capturePulse &+= 1
    }

    func togglePin(_ item: ClipItem) {
        guard let record = record(withID: item.id) else { return }
        record.pinned.toggle()
        // Unpinning is a deliberate "done keeping this" action, not a signal
        // that the clip is stale — give it a fresh retention window (and let it
        // float to the top of Recent) so it never vanishes right after unpinning.
        if !record.pinned {
            record.createdAt = Date()
        }
        try? context.save()
        refresh()
    }

    func remove(_ item: ClipItem) {
        if let record = record(withID: item.id) { context.delete(record) }
        discardPayload(of: item)
        try? context.save()
        refresh()
    }

    func clear() {
        items.forEach(discardPayload)
        try? context.delete(model: ClipRecord.self)
        try? context.save()
        refresh()
    }

    /// Prune expired rows, persist, and republish. Safe to call any time — runs
    /// on launch, on the periodic timer, and when the retention setting changes.
    func pruneExpired() {
        deleteExpiredRecords()
        try? context.save()
        refresh()
    }

    // MARK: - Retention

    /// Delete unpinned rows older than the retention window. Does not save or
    /// republish — callers do (so a single capture only saves once).
    private func deleteExpiredRecords() {
        guard retentionDays > 0,
              let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())
        else { return }
        let descriptor = FetchDescriptor<ClipRecord>(
            predicate: #Predicate { $0.pinned == false && $0.createdAt < cutoff }
        )
        guard let expired = try? context.fetch(descriptor) else { return }
        for record in expired { delete(record) }
    }

    private func startRetentionTimer() {
        // Honour time-based retention even when the app sits idle between
        // copies. Half-hourly with generous tolerance keeps it near-free.
        let timer = Timer(timeInterval: 1800, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.pruneExpired() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        retentionTimer = timer
    }

    // MARK: - Persistence helpers

    private func refresh() {
        let descriptor = FetchDescriptor<ClipRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let records = (try? context.fetch(descriptor)) ?? []
        items = records.map(ClipItem.init(record:))
    }

    private func record(withID id: UUID) -> ClipRecord? {
        var descriptor = FetchDescriptor<ClipRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Delete a row and its on-disk bitmap together.
    private func delete(_ record: ClipRecord) {
        if record.kindRaw == ClipItem.Kind.image.rawValue {
            ClipStorage.deleteImage(for: record.id)
        }
        context.delete(record)
    }

    private func makeRecord(from item: ClipItem) -> ClipRecord {
        ClipRecord(
            id: item.id,
            createdAt: item.createdAt,
            kindRaw: item.kind.rawValue,
            text: item.text,
            fileBookmarks: item.fileBookmarks,
            filePaths: item.filePaths,
            imageWidth: item.imageSize.map { Double($0.width) },
            imageHeight: item.imageSize.map { Double($0.height) },
            imageHash: item.imageHash,
            pinned: item.isPinned
        )
    }

    /// Delete the on-disk bitmap belonging to an item that is leaving (or never
    /// entering) history.
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

    /// The old build kept history in `history.json` (with externalised
    /// bitmaps). We intentionally don't migrate that data — on first launch of
    /// the SwiftData build we delete the manifest and its now-orphaned bitmaps
    /// exactly once, then start fresh.
    private func cleanUpLegacyStoreIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didMigrateKey) else { return }
        try? FileManager.default.removeItem(at: ClipStorage.historyURL)
        ClipStorage.deleteAllImages()
        defaults.set(true, forKey: Self.didMigrateKey)
    }
}
