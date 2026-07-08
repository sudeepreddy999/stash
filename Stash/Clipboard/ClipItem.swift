import AppKit
import CryptoKit
import Foundation

struct ClipItem: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let kind: Kind
    let text: String?
    let fileBookmarks: [Data]?
    let filePaths: [String]?
    /// Pixel dimensions for image clips. The bitmap itself lives on disk at
    /// `ClipStorage.imageURL(for: id)`, never in the database row.
    let imageSize: CGSize?
    /// SHA-256 of the PNG bytes — lets the store de-duplicate image clips
    /// without reading files back.
    let imageHash: String?
    let pinned: Bool?

    var isPinned: Bool { pinned ?? false }

    enum Kind: String {
        case text, file, image
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        kind: Kind,
        text: String? = nil,
        fileBookmarks: [Data]? = nil,
        filePaths: [String]? = nil,
        imageSize: CGSize? = nil,
        imageHash: String? = nil,
        pinned: Bool? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.text = text
        self.fileBookmarks = fileBookmarks
        self.filePaths = filePaths
        self.imageSize = imageSize
        self.imageHash = imageHash
        self.pinned = pinned
    }

    /// Build the value-type view model from its persisted SwiftData row.
    init(record: ClipRecord) {
        self.id = record.id
        self.createdAt = record.createdAt
        self.kind = Kind(rawValue: record.kindRaw) ?? .text
        self.text = record.text
        self.fileBookmarks = record.fileBookmarks
        self.filePaths = record.filePaths
        if let w = record.imageWidth, let h = record.imageHeight {
            self.imageSize = CGSize(width: w, height: h)
        } else {
            self.imageSize = nil
        }
        self.imageHash = record.imageHash
        self.pinned = record.pinned
    }

    // MARK: - Text flavor

    /// What a text clip *is*, beyond "text". Drives the row icon, subtitle,
    /// and the OTP indicator. Detection is heuristic and bounded (only short
    /// clips get the expensive checks) so huge clips stay cheap to render.
    enum TextFlavor {
        case plain, code, link, color, otp
    }

    var textFlavor: TextFlavor {
        guard kind == .text, let text, !text.isEmpty else { return .plain }
        if text.count <= 2048 {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count <= 12, Self.looksLikeOTP(t) { return .otp }
            if t.count <= 16, Self.looksLikeHexColor(t) { return .color }
            if t.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
               t.contains("://"), URL(string: t) != nil {
                return .link
            }
        }
        if text.contains("\n"),
           text.contains("{") || text.contains("func ") || text.contains("import ") || text.contains("=>") {
            return .code
        }
        return .plain
    }

    /// 5–8 digits, optionally grouped ("483921", "483 921", "483-921").
    /// Four-digit numbers are skipped on purpose — too many years and PINs.
    private static func looksLikeOTP(_ s: String) -> Bool {
        let digits = s.filter(\.isNumber)
        guard (5...8).contains(digits.count) else { return false }
        return !s.isEmpty && s.allSatisfy { $0.isNumber || $0 == " " || $0 == "-" }
    }

    /// #RGB, #RGBA, #RRGGBB or #RRGGBBAA.
    private static func looksLikeHexColor(_ s: String) -> Bool {
        guard s.hasPrefix("#") else { return false }
        let hex = s.dropFirst()
        guard [3, 4, 6, 8].contains(hex.count) else { return false }
        return hex.allSatisfy(\.isHexDigit)
    }

    // MARK: - Row strings

    /// Short single-purpose string for list rows. Only the head of large text
    /// clips is processed — rows show at most two lines, and collapsing
    /// whitespace across a multi-megabyte string on every render is wasted
    /// work. Runs of spaces/tabs/newlines collapse to one space so indented
    /// or multi-line snippets don't render with odd gaps.
    var preview: String {
        switch kind {
        case .text:
            let head = String((text ?? "").prefix(300))
            return head
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .file:
            return (filePaths ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        case .image:
            return "Image"
        }
    }

    /// Secondary line for list rows ("Text · 128 chars", "Link", "3 files",
    /// "Image · 1280 × 800", …).
    var summary: String {
        switch kind {
        case .text:
            switch textFlavor {
            case .otp: return "One-time code"
            case .link: return "Link"
            case .color: return "Color · \(text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")"
            case .code: return "Code · \(charCountLabel)"
            case .plain: return "Text · \(charCountLabel)"
            }
        case .file:
            let n = filePaths?.count ?? 0
            return n == 1 ? "1 file" : "\(n) files"
        case .image:
            if let imageSize {
                return "Image · \(Int(imageSize.width)) × \(Int(imageSize.height))"
            }
            return "Image"
        }
    }

    private var charCountLabel: String {
        let n = text?.count ?? 0
        return "\(n) char\(n == 1 ? "" : "s")"
    }

    var symbol: String {
        switch kind {
        case .text:
            switch textFlavor {
            case .code: return "chevron.left.forwardslash.chevron.right"
            case .link: return "link"
            case .otp: return "key.fill"
            case .color: return "paintpalette.fill"
            case .plain: return "text.alignleft"
            }
        case .file: return "doc"
        case .image: return "photo"
        }
    }

    // MARK: - Pasteboard I/O

    static func fromPasteboard(_ pb: NSPasteboard) -> ClipItem? {
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty, urls.allSatisfy({ $0.isFileURL }) {
            let bookmarks: [Data] = urls.compactMap {
                try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            return ClipItem(
                kind: .file,
                fileBookmarks: bookmarks.isEmpty ? nil : bookmarks,
                filePaths: urls.map { $0.path }
            )
        }

        let string = pb.string(forType: .string)
        let hasBitmap = pb.availableType(from: [.png, .tiff]) != nil

        // Browsers put the source URL on the pasteboard next to a copied
        // image; spreadsheets put a bitmap snapshot next to copied cells.
        // Prefer the bitmap only when the string is absent, blank, or just a
        // URL — otherwise the string is the content the user meant to copy.
        if hasBitmap, isBlankOrURL(string), let item = imageItem(from: pb) {
            return item
        }
        if let string, !string.isEmpty {
            return ClipItem(kind: .text, text: string)
        }
        if hasBitmap, let item = imageItem(from: pb) {
            return item
        }
        return nil
    }

    private static func isBlankOrURL(_ s: String?) -> Bool {
        guard let s else { return true }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        return trimmed.contains("://")
    }

    private static func imageItem(from pb: NSPasteboard) -> ClipItem? {
        // Keep original PNG bytes when the source app provides them;
        // re-encoding via TIFF is a lossy-metadata fallback.
        let png: Data?
        if let data = pb.data(forType: .png) {
            png = data
        } else if let img = NSImage(pasteboard: pb),
                  let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) {
            png = rep.representation(using: .png, properties: [:])
        } else {
            png = nil
        }
        guard let png else { return nil }

        let id = UUID()
        guard ClipStorage.writeImage(png, for: id) else { return nil }
        return ClipItem(
            id: id,
            kind: .image,
            imageSize: ClipStorage.pixelSize(of: png),
            imageHash: pngHash(of: png)
        )
    }

    static func pngHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func writeToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch kind {
        case .text:
            if let text { pb.setString(text, forType: .string) }
        case .file:
            let urls = resolvedFileURLs()
            if !urls.isEmpty { pb.writeObjects(urls as [NSURL]) }
        case .image:
            if let data = ClipStorage.imageData(for: id) {
                // Offer both PNG (original bytes) and TIFF so apps that only
                // read one of the two still get the paste.
                pb.setData(data, forType: .png)
                if let tiff = NSImage(data: data)?.tiffRepresentation {
                    pb.setData(tiff, forType: .tiff)
                }
            }
        }
    }

    /// Prefer the security-scoped bookmarks captured at copy time — they
    /// track files across moves and renames. Fall back to the recorded paths
    /// for entries whose bookmark is gone or no longer resolves.
    private func resolvedFileURLs() -> [URL] {
        var urls: [URL] = []
        for bookmark in fileBookmarks ?? [] {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                urls.append(url)
            }
        }
        if urls.isEmpty {
            urls = (filePaths ?? []).map { URL(fileURLWithPath: $0) }
        }
        return urls
    }
}
