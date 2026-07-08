import AppKit
import ImageIO
import SwiftUI

/// Decoded-image helpers for the UI layer.
///
/// Thumbnails are downsampled straight from the on-disk PNG via ImageIO —
/// the full bitmap is never decoded into memory — and memoised in a bounded
/// cache so list rows stay cheap to render.
@MainActor
enum ClipVisuals {
    private static let thumbnails: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    /// Small preview image. `side` is in points; scaled for Retina.
    static func thumbnail(for item: ClipItem, side: CGFloat = 64) -> NSImage? {
        guard item.kind == .image else { return nil }
        let key = item.id as NSUUID
        if let cached = thumbnails.object(forKey: key) { return cached }

        let src = CGImageSourceCreateWithURL(ClipStorage.imageURL(for: item.id) as CFURL, nil)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side * scale
        ]
        guard let src,
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        else { return nil }

        let image = NSImage(
            cgImage: cg,
            size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
        )
        thumbnails.setObject(image, forKey: key)
        return image
    }

    /// Finder icon for the first file in a file clip. Works even if the file
    /// has since been deleted (Finder falls back to a generic document icon).
    static func fileIcon(for item: ClipItem) -> NSImage? {
        guard item.kind == .file, let path = item.filePaths?.first else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }

    /// Parse "#RGB", "#RGBA", "#RRGGBB" or "#RRGGBBAA" into a color for the
    /// swatch shown on color clips.
    static func color(fromHex text: String?) -> Color? {
        guard let text else { return nil }
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()

        // Expand shorthand (#RGB → #RRGGBB, #RGBA → #RRGGBBAA).
        if hex.count == 3 || hex.count == 4 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }

        let hasAlpha = hex.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// Leading square in a clip row: a real thumbnail for images, the Finder
/// icon for files, a live swatch for copied colors, and an SF Symbol on a
/// subtle tile otherwise. Shared by the cursor popup and the menu-bar list
/// so the two stay visually consistent.
struct ClipLeadingVisual: View {
    let item: ClipItem
    var side: CGFloat = 32

    var body: some View {
        Group {
            if item.kind == .image, let thumb = ClipVisuals.thumbnail(for: item, side: side * 2) {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if item.kind == .file, let icon = ClipVisuals.fileIcon(for: item) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(side * 0.08)
            } else if item.textFlavor == .color, let color = ClipVisuals.color(fromHex: item.text) {
                RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                    .fill(color)
                    .overlay(
                        RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 1)
                    )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                    Image(systemName: item.symbol)
                        .font(.system(size: side * 0.42, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
    }
}

/// Small trailing indicator for time-sensitive clips. One-time codes get an
/// amber "OTP" tag so it's obvious at a glance which entry is the code that
/// just arrived — and a reminder that it probably expires soon.
struct ClipFlavorBadge: View {
    let item: ClipItem

    var body: some View {
        if item.textFlavor == .otp {
            Label("OTP", systemImage: "clock.fill")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Color.orange.opacity(0.18)))
                .foregroundStyle(.orange)
        }
    }
}
