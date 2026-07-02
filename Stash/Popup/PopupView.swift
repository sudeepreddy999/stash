import SwiftUI
import AppKit

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

    /// Height of the items area alone (the region below the header). An
    /// expanded snippet card grows to fill exactly this, so the panel frame
    /// never has to change when a snippet is expanded.
    static func itemsAreaHeight(rows: Int) -> CGFloat {
        rows <= 0
            ? emptyHeight
            : CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowSpacing
    }

    static func panelHeight(rows: Int) -> CGFloat {
        outerPadding * 2 + headerHeight + stackSpacing + itemsAreaHeight(rows: rows)
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
                itemsArea
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
            Text(controller.isExpanded ? "←  back    P  pin    ↩  paste    esc" : "↑↓  →  ↩  1–5  P  ⌫  esc")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .contentTransition(.opacity)
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

    /// The region below the header. The stack of rows and the single expanded
    /// card live in the same fixed-height slot; expanding cross-fades the list
    /// out while the selected card grows up from its row to fill the slot, so
    /// the panel frame never changes.
    private var itemsArea: some View {
        let areaHeight = PopupMetrics.itemsAreaHeight(rows: items.count)
        let selected = min(max(0, controller.selection), items.count - 1)
        let rowStride = PopupMetrics.rowHeight + PopupMetrics.rowSpacing
        let collapsedOffset = CGFloat(selected) * rowStride

        return ZStack(alignment: .top) {
            itemsList
                .allowsHitTesting(!controller.isExpanded)

            // Always mounted so it can animate in *and* out. When collapsed it
            // sits invisibly exactly over the selected row (same height, same
            // offset), so expanding reads as that row growing into place.
            ExpandedItemCard(
                item: controller.expandedItem ?? items[selected],
                index: selected + 1,
                selection: controller.expandedSelection,
                onBack: { controller.collapse() },
                onPaste: { controller.pasteSelected() },
                onCopy: { controller.copyExpandedSelection() },
                onTogglePin: { controller.togglePinSelected() },
                onSelectionChange: { controller.setExpandedSelection($0) }
            )
            .frame(height: controller.isExpanded ? areaHeight : PopupMetrics.rowHeight)
            .offset(y: controller.isExpanded ? 0 : collapsedOffset)
            .opacity(controller.isExpanded ? 1 : 0)
            .allowsHitTesting(controller.isExpanded)
        }
        .frame(height: areaHeight)
        // Clip to the items area (with breathing room for the blob shadows) so
        // rows sliding out on expand disappear at the popup edge instead of
        // spilling over the header or off the panel. The top inset only reaches
        // the header gap; the others keep the full shadow spread.
        .padding(EdgeInsets(top: PopupMetrics.stackSpacing,
                            leading: PopupMetrics.outerPadding,
                            bottom: PopupMetrics.outerPadding,
                            trailing: PopupMetrics.outerPadding))
        .clipped()
        .padding(EdgeInsets(top: -PopupMetrics.stackSpacing,
                            leading: -PopupMetrics.outerPadding,
                            bottom: -PopupMetrics.outerPadding,
                            trailing: -PopupMetrics.outerPadding))
    }

    private var itemsList: some View {
        let areaHeight = PopupMetrics.itemsAreaHeight(rows: items.count)
        let selected = min(max(0, controller.selection), items.count - 1)
        return VStack(spacing: PopupMetrics.rowSpacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                ItemBlob(
                    item: item,
                    index: idx + 1,
                    isSelected: idx == controller.selection,
                    onTogglePin: { controller.togglePin(at: idx) }
                )
                .contentShape(RoundedRectangle(cornerRadius: PopupMetrics.cornerRadius, style: .continuous))
                .onTapGesture { controller.paste(at: idx) }
                .onHover { hovering in
                    if hovering { controller.hover(idx) }
                }
                .modifier(BlobReveal(index: idx, reveal: reveal))
                // On expand, rows above the selection slide up and out the top,
                // rows below slide down and out the bottom; the selected row
                // just fades as the card grows over it.
                .offset(y: pushOffset(for: idx, selected: selected, area: areaHeight))
                .opacity(controller.isExpanded && idx == selected ? 0 : 1)
            }
        }
    }

    /// How far a row is shoved off-screen when a *different* row is expanded.
    /// One full items-area height guarantees it clears the clip boundary
    /// regardless of where it sits in the list.
    private func pushOffset(for index: Int, selected: Int, area: CGFloat) -> CGFloat {
        guard controller.isExpanded, index != selected else { return 0 }
        return index < selected ? -area : area
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
    var onTogglePin: () -> Void = {}

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
            pinAccessory
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

    /// The selected blob exposes a tappable pin toggle (mirroring the ⇧-free
    /// `P` shortcut); every other pinned blob keeps a static pin so you can
    /// tell at a glance which clips are pinned to the top.
    @ViewBuilder
    private var pinAccessory: some View {
        if isSelected {
            Button(action: onTogglePin) {
                Image(systemName: item.isPinned ? "pin.slash.fill" : "pin.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.isPinned ? Color.accentColor : Color.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.isPinned ? "Unpin" : "Pin to top")
        } else if item.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor.opacity(0.8))
        }
    }
}

// MARK: - Expanded item card

/// The full-height view of a single clip. Shown when the user hits the right
/// arrow: a compact header (index, kind, back/paste actions) over a scrollable
/// body that renders the clip's entire contents.
struct ExpandedItemCard: View {
    let item: ClipItem
    let index: Int
    /// The user's live text selection inside this card ("" when nothing is
    /// highlighted). Drives the sub-selection copy/paste affordances.
    var selection: String = ""
    var onBack: () -> Void
    var onPaste: () -> Void
    var onCopy: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onSelectionChange: (String) -> Void = { _ in }

    /// Brief "Copied" confirmation after the copy button is pressed.
    @State private var copied = false

    private var hasSelection: Bool { !selection.isEmpty }
    private var isText: Bool { item.kind == .text }

    private static let timeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            contents(for: item)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Text clips get a dedicated action bar so a highlighted portion
            // can be copied or pasted on its own. Other kinds keep Paste in the
            // header (there's nothing to sub-select).
            if isText {
                selectionBar
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
        .glassEffect(in: RoundedRectangle(cornerRadius: PopupMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PopupMetrics.cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.9))
                    .frame(width: 18, height: 18)
                Text("\(index)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            ClipLeadingVisual(item: item, side: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.summary)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(Self.timeFormatter.localizedString(for: item.createdAt, relativeTo: Date()))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            pinPill
            actionPill(symbol: "arrow.left", label: "Back", prominent: false, action: onBack)
            if !isText {
                actionPill(symbol: "return", label: "Paste", prominent: true, action: onPaste)
            }
        }
    }

    /// Action bar under a text clip: reflects the current selection and offers
    /// copy/paste of just that portion (or the whole clip when nothing is
    /// highlighted).
    private var selectionBar: some View {
        HStack(spacing: 8) {
            Image(systemName: hasSelection ? "text.cursor" : "hand.point.up.left")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(selectionStatus)
                .font(.system(size: 10))
                .foregroundStyle(hasSelection ? .secondary : .tertiary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Button {
                onCopy()
                flashCopied()
            } label: {
                pillContent(symbol: copied ? "checkmark" : "doc.on.doc",
                            label: copied ? "Copied" : "Copy",
                            prominent: false)
            }
            .buttonStyle(.plain)
            .disabled(!hasSelection)
            .opacity(hasSelection ? 1 : 0.4)
            .help("Copy the highlighted text")

            Button(action: onPaste) {
                pillContent(symbol: "return",
                            label: hasSelection ? "Paste part" : "Paste all",
                            prominent: true)
            }
            .buttonStyle(.plain)
            .help(hasSelection ? "Paste just the highlighted text" : "Paste the whole clip")
        }
    }

    private var selectionStatus: String {
        guard hasSelection else { return "Select text to grab just a part" }
        let n = selection.count
        return "\(n) character\(n == 1 ? "" : "s") selected"
    }

    private func flashCopied() {
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    /// Icon-only capsule so the two labelled pills stay the visual anchors.
    /// Fills with the accent when pinned so the state reads even without a label.
    private var pinPill: some View {
        Button(action: onTogglePin) {
            Image(systemName: item.isPinned ? "pin.slash" : "pin")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(item.isPinned ? Color.accentColor.opacity(0.9) : Color.secondary.opacity(0.18))
                )
                .foregroundStyle(item.isPinned ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(item.isPinned ? "Unpin" : "Pin to top")
    }

    private func actionPill(symbol: String, label: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            pillContent(symbol: symbol, label: label, prominent: prominent)
        }
        .buttonStyle(.plain)
    }

    private func pillContent(symbol: String, label: String, prominent: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(prominent ? Color.accentColor.opacity(0.9) : Color.secondary.opacity(0.18))
        )
        .foregroundStyle(prominent ? Color.white : Color.secondary)
    }

    @ViewBuilder
    private func contents(for item: ClipItem) -> some View {
        switch item.kind {
        case .text:
            SelectableTextView(
                text: item.text ?? "",
                isMonospaced: item.textFlavor == .code,
                onSelectionChange: onSelectionChange
            )
        case .image:
            if let thumb = ClipVisuals.thumbnail(for: item, side: 640) {
                ScrollView {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            } else {
                unavailable("Image unavailable")
            }
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(item.filePaths ?? [], id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable()
                                .frame(width: 20, height: 20)
                            Text((path as NSString).lastPathComponent)
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func unavailable(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Selectable text

/// A read-only, mouse-selectable text view for the expanded card. SwiftUI's
/// `Text(...).textSelection(.enabled)` renders selectable text but never hands
/// the selected substring back, which is exactly what the sub-selection
/// copy/paste flow needs — so we drop down to `NSTextView` and report the
/// current selection up on every change.
struct SelectableTextView: NSViewRepresentable {
    let text: String
    let isMonospaced: Bool
    var onSelectionChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelectionChange: onSelectionChange) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true

        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.font = Self.font(monospaced: isMonospaced)
        textView.string = text
        // Attach the delegate *after* the initial string is set so seeding the
        // content doesn't fire a spurious empty-selection callback.
        textView.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onSelectionChange = onSelectionChange
        guard let textView = scroll.documentView as? NSTextView else { return }

        let newFont = Self.font(monospaced: isMonospaced)
        if textView.font != newFont { textView.font = newFont }

        // Only reset when the clip itself changed — never on every re-render, or
        // an in-progress selection would be wiped out. The guarded assignment
        // resets the caret, so suppress the resulting delegate callback.
        if textView.string != text {
            context.coordinator.isProgrammaticChange = true
            textView.string = text
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            context.coordinator.isProgrammaticChange = false
        }
    }

    private static func font(monospaced: Bool) -> NSFont {
        monospaced
            ? .monospacedSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 12)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelectionChange: (String) -> Void
        var isProgrammaticChange = false

        init(onSelectionChange: @escaping (String) -> Void) {
            self.onSelectionChange = onSelectionChange
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isProgrammaticChange,
                  let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            let selected = (textView.string as NSString).substring(with: range)
            onSelectionChange(selected)
        }
    }
}
