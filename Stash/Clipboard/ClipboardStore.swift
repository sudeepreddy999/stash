import Foundation
import Combine

/// On-disk history of clipboard items.
///
/// Persists JSON to `~/Library/Application Support/Stash/history.json`.
/// Emits `capturePulse` on every successful new capture — the menubar icon
/// listens to this to bounce.
@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var capturePulse: Int = 0

    private let maxItems = 100
    private let fileURL: URL

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Stash", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("history.json")
        load()
    }

    func add(_ item: ClipItem) {
        if let first = items.first, isSameContent(first, item) { return }
        items.insert(item, at: 0)
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
        capturePulse &+= 1
        save()
    }

    func remove(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    private func isSameContent(_ a: ClipItem, _ b: ClipItem) -> Bool {
        guard a.kind == b.kind else { return false }
        switch a.kind {
        case .text: return a.text == b.text
        case .file: return a.filePaths == b.filePaths
        case .image: return a.imageData == b.imageData
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Stash: failed to save history: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([ClipItem].self, from: data) {
            self.items = decoded
        }
    }
}
