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
- **Keyboard-first** — `↑` / `↓` to navigate, `↩` to paste, `1`–`5` to
  instantly paste that slot, `⌫` to delete the selected clip. `esc` dismisses.
- **Auto-paste** — Selecting a clip puts it on the pasteboard *and* posts
  `⌘V` into the app you were just using (requires Accessibility permission).
- **Menubar history** — Click the menu bar icon for the full history with
  search, pinning, per-item delete, quick clear, settings, and quit.
  Right-click the icon for a quick context menu.
- **Pinned clips** — Pin anything you paste often; pinned clips float above
  the recents and never fall out of history.
- **Smart clips** — One-time codes get an OTP badge, copied hex colors show
  a live swatch, links and code snippets get their own icons, images show
  real thumbnails with dimensions.
- **Icon animation** — The menubar icon bounces every time something new is
  captured, so you get a visible confirmation.
- **Swappable shortcut** — Settings ships a few sensible presets
  (`⌘⇧V`, `⌃⌥V`, `⌥Space`, `⌘⇧\``, `⌘⇧B`). The choice is remembered across
  launches.
- **Local storage only** — History persists to
  `~/Library/Application Support/Stash/` (a small `history.json` manifest
  plus one PNG per image clip). Nothing leaves your machine.
- **Privacy aware** — Content marked concealed or transient (passwords from
  password managers, etc.) is never captured, and one-time codes are tagged
  with an OTP badge in the list.

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
| In popup | `⌫` | Delete selected clip |
| In popup | `esc` | Dismiss |
| In popup | outside click | Dismiss |
| Menu bar icon | right-click | Quick context menu |

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

- Rich text / RTF handling
- Custom pixel-art character for the menubar icon
  (see `MenuBar/MenuBarIcon.swift` for the swap-in instructions)
- Preview on hover for images and long text

## Changelog

Newest first.

### UI polish, smarter clips & reliability — ritwikdurga · 2026-07-02

- Redesigned the popup and menu-bar list so items no longer look cramped or
  truncated — clean fixed-height rows with proper thumbnails for images and
  Finder icons for files.
- Smart clips: one-time codes get an OTP badge, hex colors show a live
  swatch, links and code snippets get their own icons, images show
  dimensions.
- Added search, pinning, and per-item delete to the menu-bar history, plus a
  right-click quick menu on the icon.
- Added Settings for launch-at-login, history size, and a warning when the
  chosen shortcut is already taken.
- Privacy: passwords and other sensitive clips are skipped automatically.
- Under the hood: images now stored as separate files (lighter, faster),
  files paste correctly even after being moved, and copy/paste is more
  reliable.

### Popup animations & escape handling — Sudeep Ogireddy · 2026-07-01 22:55

- Smoother popover and popup animations with escape-to-dismiss.

### Draggable popups — Sudeep Ogireddy · 2026-07-01 22:11

- Popups can be dragged around, plus escape-key handling.

### First working version — Sudeep Ogireddy · 2026-07-01 17:33

- Initial clipboard manager: capture, cursor popup, menu-bar history.

## Open source

- Contributions: see [CONTRIBUTING.md](CONTRIBUTING.md)
- Code of Conduct: see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
- Security policy: see [SECURITY.md](SECURITY.md)
- Pull request template: [`.github/pull_request_template.md`](.github/pull_request_template.md)

## License

MIT (see [LICENSE](LICENSE)).
