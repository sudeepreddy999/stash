import SwiftUI

/// Single source of truth for popup geometry. `PopupController` sizes the
/// NSPanel from these numbers and the SwiftUI layout consumes the same ones,
/// so the panel frame always matches the rendered content exactly — rows are
/// fixed-height on purpose (variable-height rows are what previously left a
/// dead gap at the bottom of the panel).
enum PopupMetrics {
    static let panelWidth: CGFloat = 400
    static let outerPadding: CGFloat = 10
    static let headerHeight: CGFloat = 34
    static let stackSpacing: CGFloat = 8
    static let rowHeight: CGFloat = 60
    static let rowSpacing: CGFloat = 6
    static let emptyHeight: CGFloat = 130
    static let cornerRadius: CGFloat = 14

    static func panelHeight(rows: Int) -> CGFloat {
        let content: CGFloat = rows == 0
            ? emptyHeight
            : CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowSpacing
        return outerPadding * 2 + headerHeight + stackSpacing + content
    }
}

/// The floating popup that appears near the cursor — a stack of independent
/// **blobs** rather than a single container.
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
/// ```
///
/// Each blob gets liquid glass, a subtle shadow, and a fixed height.
struct PopupView: View {
    @ObservedObject var controller: PopupController
    @EnvironmentObject var store: ClipboardStore

    /// Drives the blob entrance animation. Flipped off→on whenever the popup
    /// (re)appears so the blobs cascade in.
    @State private var reveal = false

    private var items: [ClipItem] { controller.visibleItems }

    var body: some View {
        VStack(spacing: PopupMetrics.stackSpacing) {
            headerBlob

            if items.isEmpty {
                emptyBlob
            } else {
                itemsList
            }
        }
        .padding(PopupMetrics.outerPadding)
        .frame(width: PopupMetrics.panelWidth)
        // Full-panel background catches clicks in the gaps between blobs
        // so the popup dismisses on empty-space taps.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { controller.hide() }
        )
        .onAppear { reveal = true }
        .onChange(of: controller.revealToken) { _, _ in
            // Reset instantly, then cascade back in on the next runloop tick.
            reveal = false
            DispatchQueue.main.async { reveal = true }
        }
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
            Text("↑↓  ↩  1–5  ⌫  esc")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: PopupMetrics.headerHeight)
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        .glassEffect()
        // The header doubles as a title bar: grab it to drag the popup around,
        // just like a normal window.
        .overlay(WindowDragHandle())
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
        .frame(height: PopupMetrics.emptyHeight)
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Items

    private var itemsList: some View {
        VStack(spacing: PopupMetrics.rowSpacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                ItemBlob(
                    item: item,
                    index: idx + 1,
                    isSelected: idx == controller.selection
                )
                .contentShape(RoundedRectangle(cornerRadius: PopupMetrics.cornerRadius, style: .continuous))
                .onTapGesture { controller.paste(at: idx) }
                .onHover { hovering in
                    if hovering { controller.hover(idx) }
                }
                .modifier(BlobReveal(index: idx, reveal: reveal))
            }
        }
    }
}

// MARK: - Blob entrance animation

/// Fades + slides + subtly scales a blob into place, staggered by its row
/// index so the list cascades in. Reset is instantaneous (no reverse
/// animation) so re-showing the popup replays a clean entrance.
private struct BlobReveal: ViewModifier {
    let index: Int
    let reveal: Bool

    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .scaleEffect(shown ? 1 : 0.96, anchor: .top)
            .onAppear { if reveal { animateIn() } }
            .onChange(of: reveal) { _, isRevealing in
                if isRevealing { animateIn() } else { shown = false }
            }
    }

    private func animateIn() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)
            .delay(Double(index) * 0.05)) {
            shown = true
        }
    }
}

// MARK: - Item blob

struct ItemBlob: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool

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
            ClipLeadingVisual(item: item, side: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(item.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ClipFlavorBadge(item: item)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: PopupMetrics.rowHeight)
        .shadow(color: .black.opacity(isSelected ? 0.22 : 0.14), radius: isSelected ? 8 : 5, y: 2)
        .glassEffect(in: RoundedRectangle(cornerRadius: PopupMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PopupMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isSelected ? 0.7 : 0), lineWidth: 1.5)
        )
    }
}
