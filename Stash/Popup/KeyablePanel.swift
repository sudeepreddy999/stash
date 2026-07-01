import AppKit

/// Borderless NSPanel that is allowed to become key so it can receive
/// keyboard input. `becomeMain` stays `false` — we're a floating chip,
/// not the primary window.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
