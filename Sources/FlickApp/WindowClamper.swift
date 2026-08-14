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

        /// SwiftUI re-lays-out this view whenever the inbox changes shape, which
        /// is the one signal that always arrives: deciding a card resizes the
        /// window, and for the menu-bar popover AppKit sets the real frame
        /// after `viewDidMoveToWindow` without a notification we can observe.
        override func layout() {
            super.layout()
            scheduleClamp()
        }

        /// Clamp after the current pass, never during it — AppKit is still
        /// positioning the window while layout runs, and a frame set now is
        /// simply overwritten.
        private func scheduleClamp() {
            guard let window else { return }
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                MainActor.assumeIsolated { Self.clamp(window) }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard window != nil else { return }
            scheduleClamp()
            // Each notification catches a different way the window can end up
            // out of bounds: growth arrives as a resize, the menu bar hiding
            // arrives as a move, and reopening a popover that AppKit reuses
            // arrives as neither.
            for name in [NSWindow.didResizeNotification,
                         NSWindow.didMoveNotification,
                         NSWindow.didBecomeKeyNotification] {
                let isMove = name == NSWindow.didMoveNotification
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak window] _ in
                    guard let window else { return }
                    MainActor.assumeIsolated { Self.clamp(window, canBeADrag: isMove) }
                })
            }
        }

        private static func clamp(_ window: NSWindow, canBeADrag: Bool = false) {
            // Only a *move* can be a live drag, and correcting one mid-gesture
            // would fight the cursor near a screen edge. A resize never is:
            // it means the inbox grew or shrank on its own. Deciding a card
            // holds the mouse button down at the instant the window resizes, so
            // treating that as a drag would skip the one correction that
            // matters most — the window resizing itself off the screen right
            // as the user clicks Allow.
            if canBeADrag, NSEvent.pressedMouseButtons != 0 { return }
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
