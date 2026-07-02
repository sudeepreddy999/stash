import SwiftUI
import AppKit

/// Contents of the menu-bar popover.
///
/// **Live updates.** Observes `ClipboardStore` directly (via `@EnvironmentObject`)
/// rather than reaching through `appState.store`. That matters because
/// `@Published` on a *nested* `ObservableObject` doesn't trigger the outer
/// `AppState`'s `objectWillChange`, so previously the list didn't refresh
/// when new items were captured while the popover was open.
///
/// **Tap-to-paste.** Rows call `appState.statusItemController?.paste(item)`,
/// which closes this popover, restores focus to the app the user was in
/// when they clicked the menu bar, and posts ⌘V.
struct MenuBarContent: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: ClipboardStore

    @State private var query = ""

    private let maxListHeight: CGFloat = 340
    private let popoverWidth: CGFloat = 320

    private var searchResults: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.items }
        return store.items.filter { matches($0, query: q) }
    }

    private func matches(_ item: ClipItem, query: String) -> Bool {
        switch item.kind {
        case .text:
            return item.text?.localizedCaseInsensitiveContains(query) ?? false
        case .file:
            return (item.filePaths ?? []).contains { $0.localizedCaseInsensitiveContains(query) }
        case .image:
            return "image".localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !store.items.isEmpty {
                searchField
            }
            Divider().opacity(0.25)
            list
            Divider().opacity(0.25)
            footer
        }
        .frame(width: popoverWidth)
    }

    private var header: some View {
        HStack {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Stash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(appState.currentHotkey.display)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                )
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("Search history", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.secondary.opacity(0.1))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var list: some View {
        if store.items.isEmpty {
            emptyState(
                symbol: "tray",
                title: "Nothing stashed yet",
                caption: "Copy something with ⌘C to get started"
            )
        } else if searchResults.isEmpty {
            emptyState(
                symbol: "magnifyingglass",
                title: "No matches",
                caption: "Nothing in history matches “\(query)”"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 2, pinnedViews: []) {
                    if query.isEmpty {
                        sectionedRows
                    } else {
                        rows(for: searchResults)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: maxListHeight)
        }
    }

    /// Pinned clips float in their own group above the recents.
    @ViewBuilder
    private var sectionedRows: some View {
        let pinned = store.pinnedItems
        if !pinned.isEmpty {
            sectionLabel("Pinned")
            rows(for: pinned)
            sectionLabel("Recent")
        }
        rows(for: store.recentItems)
    }

    @ViewBuilder
    private func rows(for items: [ClipItem]) -> some View {
        ForEach(items) { item in
            MenuClipRow(item: item)
                .contentShape(Rectangle())
                .onTapGesture {
                    appState.statusItemController?.paste(item)
                }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func emptyState(symbol: String, title: String, caption: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                // Route through the status-item controller so the popup
                // inherits the app that was frontmost before the menu bar was
                // clicked — asking `frontmostApplication` here would answer
                // "Stash", and auto-paste would go nowhere.
                appState.statusItemController?.openCursorPopup()
            } label: {
                Label("Open popup", systemImage: "rectangle.on.rectangle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Menu {
                Button("Settings…") { appState.openSettings() }
                Button("Clear history…") { appState.confirmAndClearHistory() }
                Divider()
                Button("Quit Stash") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct MenuClipRow: View {
    let item: ClipItem
    @EnvironmentObject var store: ClipboardStore
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ClipLeadingVisual(item: item, side: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.preview)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                // TimelineView keeps "5 seconds ago" honest while the
                // popover stays open.
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text("\(item.summary) · \(item.createdAt.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            ClipFlavorBadge(item: item)
            if item.isPinned && !isHovered {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            if isHovered {
                Button {
                    store.togglePin(item)
                } label: {
                    Image(systemName: item.isPinned ? "pin.slash" : "pin")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(item.isPinned ? "Unpin" : "Pin to top")

                Button {
                    store.remove(item)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from history")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}
