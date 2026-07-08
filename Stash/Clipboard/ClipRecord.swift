import Foundation
import SwiftData

/// Persisted clipboard entry — one row per stashed clip.
///
/// Image bitmaps are deliberately *not* stored in the row: they live as PNG
/// files in `ClipStorage`, keyed by `id`, so the database stays small and no
/// bitmap sits on the heap just because it's in history. The UI never touches
/// this type directly — `ClipboardStore` maps rows to value-type `ClipItem`s.
@Model
final class ClipRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    /// `ClipItem.Kind` raw value ("text" / "file" / "image").
    var kindRaw: String
    var text: String?
    var fileBookmarks: [Data]?
    var filePaths: [String]?
    /// Pixel dimensions of an image clip; the bitmap itself is on disk.
    var imageWidth: Double?
    var imageHeight: Double?
    /// SHA-256 of the PNG bytes — powers image de-duplication without reading
    /// files back.
    var imageHash: String?
    var pinned: Bool

    init(
        id: UUID,
        createdAt: Date,
        kindRaw: String,
        text: String? = nil,
        fileBookmarks: [Data]? = nil,
        filePaths: [String]? = nil,
        imageWidth: Double? = nil,
        imageHeight: Double? = nil,
        imageHash: String? = nil,
        pinned: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kindRaw = kindRaw
        self.text = text
        self.fileBookmarks = fileBookmarks
        self.filePaths = filePaths
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.imageHash = imageHash
        self.pinned = pinned
    }
}
