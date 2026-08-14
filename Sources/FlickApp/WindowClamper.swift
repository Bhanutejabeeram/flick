import AppKit
import SwiftUI

/// Pins whatever window hosts the inbox inside its screen's visible area.
///
/// The inbox appears in two windows: the MenuBarExtra popover and the floating
/// panel opened from a notification banner. Both can end up partly off-screen —
/// the popover because macOS anchors it to the menu bar, and in a full-screen
/// space the menu bar auto-hides, sliding the anchor (and the popover's top)
/// off the display; the panel because a window grows upward from a fixed
/// bottom-left corner as requests arrive. Sitting inside the shared view means
/// every window that ever hosts the inbox gets the same protection, including
/// ones AppKit creates for us that we never get a handle to any other way.
struct WindowClamper: NSViewRepresentable {
    func makeNSView(context: Context) -> ClampingView { ClampingView() }
    func updateNSView(_ nsView: ClampingView, context: Context) {}

    final class ClampingView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            Self.clamp(window)
            // Both notifications matter: growth arrives as a resize, the menu
            // bar hiding arrives as a move.
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak window] _ in
                    guard let window else { return }
                    MainActor.assumeIsolated { Self.clamp(window) }
                })
            }
        }

        private static func clamp(_ window: NSWindow) {
            // Never correct a window the user is holding. The panel is
            // drag-anywhere movable and `didMove` fires continuously through a
            // drag, so clamping mid-gesture would fight the cursor near an
            // edge. Whatever they let go of gets clamped on the next resize or
            // reopen instead.
            guard NSEvent.pressedMouseButtons == 0 else { return }
            guard let visible = PanelPlacement.screen(for: window)?.visibleFrame else { return }
            let target = PanelPlacement.clamped(window.frame, in: visible)
            // The no-op guard is what stops setFrame → didMove → clamp from
            // looping: the second pass finds nothing to correct.
            guard !target.equalTo(window.frame) else { return }
            window.setFrame(target, display: true)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
