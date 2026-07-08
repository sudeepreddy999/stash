import Foundation
import ImageIO

/// On-disk home for clipboard image payloads.
///
/// Layout:
/// ```
/// ~/Library/Application Support/Stash/
/// ├── Stash.store      ← SwiftData database (clip metadata)
/// └── images/
///     └── <item UUID>.png
/// ```
///
/// Image bytes never live in a database row: every capture writes one PNG file
/// here, read lazily and downsampled on demand, so bitmaps stay off the heap
/// until a thumbnail is actually shown. (`history.json` is the legacy JSON
/// manifest — deleted once on first launch of the SwiftData build.)
enum ClipStorage {
    static let baseURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Stash", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// SwiftData database, kept beside the images folder in Application Support.
    static let storeURL = baseURL.appendingPathComponent("Stash.store")

    /// Legacy JSON manifest — only referenced by the one-time cleanup that
    /// removes it when migrating to SwiftData.
    static let historyURL = baseURL.appendingPathComponent("history.json")

    private static let imagesURL: URL = {
        let url = baseURL.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func imageURL(for id: UUID) -> URL {
        imagesURL.appendingPathComponent("\(id.uuidString).png")
    }

    @discardableResult
    static func writeImage(_ data: Data, for id: UUID) -> Bool {
        (try? data.write(to: imageURL(for: id), options: .atomic)) != nil
    }

    static func imageData(for id: UUID) -> Data? {
        try? Data(contentsOf: imageURL(for: id))
    }

    static func deleteImage(for id: UUID) {
        try? FileManager.default.removeItem(at: imageURL(for: id))
    }

    /// Wipe every stored bitmap — used when history is cleared and during the
    /// one-time cleanup of the legacy JSON store.
    static func deleteAllImages() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: imagesURL, includingPropertiesForKeys: nil) else { return }
        for file in files { try? fm.removeItem(at: file) }
    }

    /// Remove image files whose item no longer exists — a crash between a
    /// bitmap write and a manifest save can strand one.
    static func pruneImages(keeping ids: Set<UUID>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: imagesURL, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            if let id = UUID(uuidString: name), ids.contains(id) { continue }
            try? fm.removeItem(at: file)
        }
    }

    /// Pixel dimensions read from the container header — never decodes the
    /// bitmap.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: w, height: h)
    }
}
