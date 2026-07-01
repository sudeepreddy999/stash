# Stash

An ultra-minimal, native macOS clipboard manager. Copy anything with `⌘C` or
`⌘X`, press one shortcut, pick a clip from a small liquid-glass popup that
appears right next to your cursor.

Stash lives entirely in your menu bar — no dock icon, no giant window, no
account. History is stored on-disk in your `Application Support` folder.

## Features

- **Automatic capture** — Watches the system pasteboard. Every `⌘C` / `⌘X`
  becomes a new entry (text, code, files, images).
- **Cursor popup** — A single global shortcut (default `⌘⇧V`) opens a
  380 × 260 liquid-glass card next to the mouse showing your last 5 clips.
- **Keyboard-first** — `↑` / `↓` to navigate, `↩` to paste, or press `1`–`5`
  to instantly paste that slot. `esc` dismisses.
- **Auto-paste** — Selecting a clip puts it on the pasteboard *and* posts
  `⌘V` into the app you were just using (requires Accessibility permission).
- **Menubar history** — Click the menu bar icon for the full history, quick
  clear, settings, and quit.
- **Icon animation** — The menubar icon bounces every time something new is
  captured, so you get a visible confirmation.
- **Swappable shortcut** — Settings ships a few sensible presets
  (`⌘⇧V`, `⌃⌥V`, `⌥Space`, `⌘⇧\``, `⌘⇧B`). The choice is remembered across
  launches.
- **Local storage only** — History persists to
  `~/Library/Application Support/Stash/history.json`. Nothing leaves your
  machine.

## Requirements

- macOS 26.5+ (Tahoe)
- Xcode 26.6+

## Install & run

```bash
open Stash.xcodeproj
# Product ▸ Run
```

On first launch macOS will ask for **Accessibility** permission. Grant it in
`System Settings ▸ Privacy & Security ▸ Accessibility` so Stash can auto-paste
for you. Without it, clips still land on your clipboard — you just press `⌘V`
yourself.

## Default shortcuts

| Where | Key | Action |
|-------|-----|--------|
| System-wide | `⌘⇧V` | Open the cursor popup |
| In popup | `↑` / `↓` | Move selection |
| In popup | `↩` | Paste selected clip |
| In popup | `1` – `5` | Paste that slot directly |
| In popup | `esc` | Dismiss |
| In popup | outside click | Dismiss |

## Project layout

```
Stash/
├── App/          # Entry point, delegate, root state graph
├── Clipboard/    # Pasteboard polling + history store + item model
├── Hotkey/       # Carbon global-shortcut wrapper
├── Popup/        # Floating cursor popup (NSPanel + SwiftUI view)
├── MenuBar/      # MenuBarExtra content + animated icon
└── Settings/     # Preferences window
```

For a walkthrough of every file and where to make changes, see
[`DOCS.md`](DOCS.md).

## Roadmap ideas

- Pinned clips
- Search across all history
- Rich text / RTF handling
- Custom pixel-art character for the menubar icon
  (see `MenuBar/MenuBarIcon.swift` for the swap-in instructions)
- Preview on hover for images and long text

## Open source

- Contributions: see [CONTRIBUTING.md](CONTRIBUTING.md)
- Code of Conduct: see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
- Security policy: see [SECURITY.md](SECURITY.md)
- Pull request template: [`.github/pull_request_template.md`](.github/pull_request_template.md)

## License

MIT (see [LICENSE](LICENSE)).
