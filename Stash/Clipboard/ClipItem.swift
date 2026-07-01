import AppKit
import Foundation

struct ClipItem: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let kind: Kind
    let text: String?
    let fileBookmarks: [Data]?
    let filePaths: [String]?
    let imageData: Data?

    enum Kind: String, Codable {
        case text, file, image
    }

    var preview: String {
        switch kind {
        case .text:
            return (text ?? "").replacingOccurrences(of: "\n", with: " ")
        case .file:
            return (filePaths ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        case .image:
            return "Image"
        }
    }

    var symbol: String {
        switch kind {
        case .text:
            let t = text ?? ""
            if t.contains("\n") && (t.contains("{") || t.contains("func ") || t.contains("import ") || t.contains("=>")) {
                return "chevron.left.forwardslash.chevron.right"
            }
            return "text.alignleft"
        case .file: return "doc"
        case .image: return "photo"
        }
    }

    static func fromPasteboard(_ pb: NSPasteboard) -> ClipItem? {
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty, urls.allSatisfy({ $0.isFileURL }) {
            let bookmarks: [Data] = urls.compactMap {
                try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            return ClipItem(
                id: UUID(),
                createdAt: Date(),
                kind: .file,
                text: nil,
                fileBookmarks: bookmarks.isEmpty ? nil : bookmarks,
                filePaths: urls.map { $0.path },
                imageData: nil
            )
        }
        if let str = pb.string(forType: .string), !str.isEmpty {
            return ClipItem(
                id: UUID(),
                createdAt: Date(),
                kind: .text,
                text: str,
                fileBookmarks: nil,
                filePaths: nil,
                imageData: nil
            )
        }
        if let img = NSImage(pasteboard: pb),
           let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return ClipItem(
                id: UUID(),
                createdAt: Date(),
                kind: .image,
                text: nil,
                fileBookmarks: nil,
                filePaths: nil,
                imageData: png
            )
        }
        return nil
    }

    func writeToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch kind {
        case .text:
            if let text { pb.setString(text, forType: .string) }
        case .file:
            let urls: [URL] = (filePaths ?? []).map { URL(fileURLWithPath: $0) }
            if !urls.isEmpty { pb.writeObjects(urls as [NSURL]) }
        case .image:
            if let data = imageData, let img = NSImage(data: data) {
                pb.writeObjects([img])
            }
        }
    }
}
