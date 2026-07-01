import SwiftUI

/// The floating popup that appears near the cursor — redesigned as a stack
/// of independent **blobs** rather than a single container.
///
/// Layout:
/// ```
/// ┌──────────────────────────────┐  ← header blob
/// │ 🔳 Stash              ↑↓ ↩ esc │
/// └──────────────────────────────┘
///
/// ┌──────────────────────────────┐  ← item blob (repeats)
/// │ 1  📄 First clip preview     │
/// └──────────────────────────────┘
/// ┌──────────────────────────────┐
/// │ 2  📄 Second clip            │
/// └──────────────────────────────┘
///  …
///
/// ```
///
/// Each blob has its own `.regularMaterial` (the native macOS liquid-glass
/// look), a hairline border, and a subtle shadow.
struct PopupView: View {
    @ObservedObject var controller: PopupController
    @EnvironmentObject var store: ClipboardStore

    private let blobCornerRadius: CGFloat = 14

    private var items: [ClipItem] { controller.visibleItems }

    var body: some View {
        VStack(spacing: 8) {
            headerBlob

            if items.isEmpty {
                emptyBlob
            } else {
                itemsList
            }
        }
        .padding(10)
        .frame(width: 400)
        // Full-panel background catches clicks in the gaps between blobs
        // so the popup dismisses on empty-space taps.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { controller.hide() }
        )
    }

    // MARK: - Header

    private var headerBlob: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Stash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("↑↓  ↩  1–5  esc")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        .glassEffect()
    }

    // MARK: - Empty state

    private var emptyBlob: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing stashed yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Copy something with ⌘C to get started")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 130)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: blobCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: blobCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .glassEffect()
    }

    // MARK: - Items

    private var itemsList: some View {
        LazyVStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                ItemBlob(
                    item: item,
                    index: idx + 1,
                    isSelected: idx == controller.selection,
                    cornerRadius: blobCornerRadius
                )
                .contentShape(RoundedRectangle(cornerRadius: blobCornerRadius, style: .continuous))
                .onTapGesture { controller.paste(at: idx) }
                .onHover { hovering in
                    if hovering { controller.hover(idx) }
                }
            }
        }
        .padding(.vertical, 2)
        .frame(height: controller.listViewportHeight, alignment: .top)
    }
}

// MARK: - Item blob

struct ItemBlob: View {
    private let minBlobHeight: CGFloat = 44
    private let maxBlobHeight: CGFloat = 74

    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let cornerRadius: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.9) : Color.secondary.opacity(0.18))
                    .frame(width: 18, height: 18)
                Text("\(index)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? .white : .secondary)
            }
            iconView
            VStack(alignment: .leading, spacing: 1) {
                Text(item.preview)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: minBlobHeight, maxHeight: maxBlobHeight, alignment: .center)
        .shadow(color: .black.opacity(isSelected ? 0.22 : 0.14), radius: isSelected ? 8 : 5, y: 2)
        .glassEffect()
    }

    @ViewBuilder
    private var iconView: some View {
        if item.kind == .image, let data = item.imageData, let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: item.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
    }

    private var subtitle: String {
        switch item.kind {
        case .text:
            let n = (item.text ?? "").count
            return "Text · \(n) char\(n == 1 ? "" : "s")"
        case .file:
            let n = item.filePaths?.count ?? 0
            return "File\(n == 1 ? "" : "s") · \(n)"
        case .image:
            return "Image"
        }
    }
}
