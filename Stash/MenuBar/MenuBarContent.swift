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

    private let maxListHeight: CGFloat = 340
    private let popoverWidth: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            header
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

    @ViewBuilder
    private var list: some View {
        if store.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Nothing stashed yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(store.items.enumerated()), id: \.element.id) { idx, item in
                        MenuClipRow(item: item, index: idx + 1)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                appState.statusItemController?.paste(item)
                            }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: maxListHeight)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                // Close ourselves (the popover) so focus goes back before the
                // cursor popup positions itself.
                NSApp.sendAction(#selector(NSPopover.performClose(_:)), to: nil, from: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    appState.popup.show()
                }
            } label: {
                Label("Open popup", systemImage: "rectangle.on.rectangle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Menu {
                Button("Settings…") { appState.openSettings() }
                Button("Clear history") { appState.store.clear() }
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
    let index: Int
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.preview)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(item.createdAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
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
