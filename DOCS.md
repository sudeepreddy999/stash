# Stash — Architecture & Contributor Guide

Stash is a small, single-target SwiftUI + AppKit app. There are no external
dependencies. The whole app is organized so that each concern lives in its
own folder and file — if you want to change the way something behaves, this
document tells you exactly where to look.

## Data flow at a glance

```
                                      ┌─────────────────┐
    ⌘C / ⌘X in any app  ──────────►   │  NSPasteboard   │
                                      └────────┬────────┘
                                               │ polled every 0.4s
                                               ▼
                                      ┌─────────────────┐         ┌────────────┐
                                      │ClipboardMonitor │────►────│ClipboardStore│──► history.json
                                      └────────┬────────┘         └─────┬──────┘
                                               │                        │
                                               │ capturePulse++         │ items[]
                                               ▼                        ▼
                                      ┌─────────────────┐       ┌────────────┐
                                      │  MenuBarIcon    │       │ PopupView  │
                                      │  (bounce)       │       │ MenuBar    │
                                      └─────────────────┘       └────┬───────┘
                                                                     │ paste(idx)
    Global shortcut (Carbon) ──► HotkeyManager ──► popup.toggle()    │
                                                                     ▼
                                                            item.writeToPasteboard()
                                                            previousApp.activate()
                                                            CGEvent(⌘V)
```

## Folder guide

### `Stash/App/` — entry point & lifecycle

- **`StashApp.swift`** — `@main` `App` scene. Declares the `MenuBarExtra`
  (using `MenuBarIcon` as its label) and a `Settings` scene. Wires the
  `AppDelegate` via `NSApplicationDelegateAdaptor`.
- **`AppDelegate.swift`** — Sets `NSApp.setActivationPolicy(.accessory)` so
  Stash has no dock icon. Calls `appState.start()` on launch. This is the
  place to add any one-shot boot logic (login items, sparkle setup, etc.).
- **`AppState.swift`** — The single owning object graph. Holds the store,
  monitor, popup controller, and hotkey manager. Also owns the current
  hotkey (persisted through `UserDefaults`) and the Accessibility prompt.

### `Stash/Clipboard/` — capture + storage

- **`ClipItem.swift`** — The `Codable` model for a clip. Three kinds:
  `.text`, `.file`, `.image`. `fromPasteboard(_:)` reads whichever type
  is on the pasteboard; `writeToPasteboard()` restores it. Change here if
  you want to add a new clip kind (RTF, colors, …).
- **`ClipboardStore.swift`** — The on-disk history. Prepends new items,
  caps at 100, dedupes against the most recent, atomically writes JSON
  to `~/Library/Application Support/Stash/history.json`. `capturePulse`
  is a monotonically increasing counter that the menu bar icon watches
  to trigger the bounce animation.
- **`ClipboardMonitor.swift`** — Polls `NSPasteboard.changeCount` every
  0.4 s. When it changes, extracts a `ClipItem` and hands it to the store.
  `suppressNext()` is called by the popup right before *we* write to the
  pasteboard, so re-pasting an old clip doesn't create a new history entry.

### `Stash/Hotkey/` — the global shortcut

- **`HotkeyManager.swift`** — Thin wrapper around Carbon's
  `RegisterEventHotKey`. Carbon is intentionally used (not
  `NSEvent.addGlobalMonitorForEvents`) because it doesn't require the
  Accessibility entitlement. The `Hotkey` struct is `Codable`+`Hashable` so
  it can be persisted and used in `Picker`s.

### `Stash/Popup/` — the cursor chip

- **`KeyablePanel.swift`** — A minimal `NSPanel` subclass whose
  `canBecomeKey` is `true`. Without this a borderless panel refuses
  keyboard input.
- **`PopupController.swift`** — The brains of the popup.
  - Builds the panel lazily.
  - Positions it near `NSEvent.mouseLocation`, clamped inside
    `screen.visibleFrame`.
  - **Focus dance:** remembers `NSWorkspace.frontmostApplication` on show,
    activates our app so key events flow to the panel, then on paste
    reactivates the previous app *before* posting the synthetic `⌘V` so
    the paste lands where the user was typing.
  - Installs an `NSEvent` local key monitor + global outside-click monitor
    while visible. Keys handled: `esc`, `↑`, `↓`, `↩`, `1`–`5`.
  - Simulates `⌘V` with `CGEvent`.
  - **Dynamic height + lazy load:** `loadedLimit` starts at 5. The view
    calls `loadMore()` from the last row's `.onAppear`, which bumps the
    limit by `pageSize` and animates the panel to a taller frame
    (anchored at the top so it grows *downward*). Height is capped at
    `maxHeight`; beyond that the list scrolls inside the fixed frame.
  - Subscribes to `store.$items` while visible so new copies made *while*
    the popup is open cause the panel to reflow.
- **`PopupView.swift`** — Pure presentation.
  - Observes `controller.selection`, `controller.loadedLimit`,
    `controller.hasMore`.
  - Renders items inside a `ScrollView` + `LazyVStack`; the last row's
    `.onAppear` calls `controller.loadMore()`.
  - Below the list, a small "N more" strip appears whenever `hasMore`.
    Tapping it also calls `loadMore()`.
  - The card is `.clipShape(RoundedRectangle)` so overflowing content
    can never break the rounded corners.
  - The **liquid-glass** background is a `ZStack` of: `.regularMaterial`
    base, an `.ultraThinMaterial` `.plusLighter` overlay, a top-edge
    specular highlight, a bottom-edge inner shadow, and a gradient
    stroke on the border. All contained inside the same rounded rect.

### `Stash/MenuBar/` — the menu bar UI

- **`StatusItemController.swift`** — Owns the real `NSStatusItem`. We
  don't use SwiftUI's `MenuBarExtra` because its label is rendered as a
  snapshot in some macOS builds, so SwiftUI animations never appeared.
  This class:
  - hosts the status-bar `NSButton` with an SF Symbol template image,
  - shows an `NSPopover` containing `MenuBarContent` on click,
  - subscribes to `store.$capturePulse` and runs a `CAKeyframeAnimation`
    hop + wiggle on every capture,
  - is the file to edit when swapping in a pixel-art character
    (replace the button image with a `NoHitHostingView` wrapping a
    SwiftUI `TimelineView` of your frames).
- **`MenuBarContent.swift`** — The popover contents: full scrollable
  history, current shortcut chip, and an overflow menu with Settings /
  Clear / Quit. Settings opens via `appState.openSettings()` (manual
  `NSWindow`) rather than the flaky SwiftUI `openSettings` environment
  key.

### `Stash/Settings/` — preferences

- **`SettingsView.swift`** — A `Form(.grouped)` window shown by the
  `Settings` scene in `StashApp.swift`. Three sections: shortcut picker
  (five presets), history stats + clear, and an Accessibility deep link.

## Key design decisions

**Why a Carbon hotkey?** `NSEvent.addGlobalMonitorForEvents(.keyDown …)`
requires Input Monitoring / Accessibility. Carbon's `RegisterEventHotKey`
works with no extra entitlement and is the standard for lightweight
launchers.

**Why a `.nonactivating` panel was *removed*.** Early on the panel used
`.nonactivatingPanel` so it wouldn't steal focus, but that meant SwiftUI
never received key events — the underlying app kept them. Now the panel is
a plain borderless `NSPanel`, we activate ourselves on show, and hand
focus back to the previous app right before pasting.

**Why poll the pasteboard?** macOS has no public "pasteboard changed"
notification. Every clipboard manager (Alfred, Raycast, Pastebot, …)
polls `changeCount`. 0.4 s is a good balance between responsiveness and
CPU idle.

**Why disable App Sandbox?** Auto-paste needs `CGEvent.post`, which the
sandbox doesn't allow. Sandboxed clipboard managers exist but the UX
around fileURL security-scoped bookmarks is painful for the MVP.

## Extending the app

**Add a new kind of clip (e.g. colors):**
1. Add a case to `ClipItem.Kind`.
2. Extend `fromPasteboard(_:)` and `writeToPasteboard()`.
3. Handle the icon/preview in `ClipItem.symbol` and `PopupView.ClipRow`.

**Change how many items appear in the popup:**
Edit `visibleItemCount` in `PopupController`. Also bump the digit range
in `handleKey(_:)` if you go past 9.

**Add a new hotkey preset:**
Append to the `presets` array in `SettingsView`. The `Hotkey`
initializer takes a Carbon virtual key code (`kVK_ANSI_*`) plus a
modifier mask (`cmdKey | shiftKey | optionKey | controlKey`).

**Swap the menubar icon for a pixel character:**
See the doc comment at the top of `MenuBar/MenuBarIcon.swift`. Short
version: draw 22-pt frames in Aseprite/Piskel, drop the PNGs into
`Assets.xcassets`, and drive an index with `TimelineView(.animation)`.

**Persist somewhere other than JSON:**
Replace the `save()`/`load()` implementations in `ClipboardStore`. Nothing
else in the app knows about the file format.

## How does the Run scheme find files under `App/`, `Popup/`, …?

The Xcode project uses a **`PBXFileSystemSynchronizedRootGroup`** (Xcode 16+,
opt-in from the "New Project" template). Instead of the classic behaviour
of enumerating every source file inside `project.pbxproj`, the project
declares a single group with `path = Stash;` and the build target
`fileSystemSynchronizedGroups = ( Stash )`.

At build time Xcode walks that directory *recursively* and picks up every
file with a known extension (`.swift`, `.xcassets`, `.storyboard`, …) as
part of the target. So when we moved everything into `App/`, `Popup/`,
`MenuBar/`, etc., **the project file needed no changes** — the folders
are still under `Stash/` so they were picked up automatically.

The Run scheme (`Stash.xcodeproj/xcshareddata/xcschemes/Stash.xcscheme`, or
the auto-generated per-user one) just points at the `Stash` target and hits
Build → Launch on that target's `.app` bundle. There is nothing in the
scheme that mentions individual files.

Practical implication: **adding a new file is just `touch Stash/Foo/Bar.swift`
followed by a rebuild**, no Xcode UI click needed. Removing a file is `rm`.
The one thing to avoid is naming a file `.swift` that you *don't* want
compiled — everything under `Stash/` ends up in the build.

## Where things live on disk

| Purpose | Path |
|---------|------|
| History | `~/Library/Application Support/Stash/history.json` |
| Preferences | `~/Library/Preferences/com.sudeepogireddy.Stash.plist` (via `UserDefaults`) |

## Known limitations / MVP shortcuts

- No search, no pinning, no tagging.
- Only the last 100 clips are kept.
- Images are stored inline (PNG) inside the JSON file — fine for a few
  screenshots, wasteful for hundreds. Migrate to a `blobs/` sidecar
  directory when you notice the file getting large.
- File clips remember the *path*, not a security-scoped bookmark. If the
  file moves after being copied, re-pasting will fail. Fixed once you
  turn the sandbox back on with proper bookmarks.
- The menubar bounce assumes `.symbolEffect` is available (macOS 14+).
