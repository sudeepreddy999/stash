import SwiftUI
import AppKit

/// A transparent region that lets the user drag the enclosing (borderless)
/// window, the way a title bar moves a normal window.
///
/// Overlay it on top of a "grab" area (e.g. the popup header). It forwards the
/// initial `mouseDown` to `NSWindow.performDrag(with:)`, which runs AppKit's
/// native window-move loop — so the popup follows the cursor until the mouse is
/// released. Because it only captures clicks over the area it covers, the rest
/// of the popup keeps its normal tap-to-paste / tap-to-dismiss behavior.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DraggableView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableView: NSView {
        // Allow starting a drag even if the click is what first activates the panel.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

