import AppKit
import CoreGraphics

/// Geometry for the windows that host the inbox, kept apart from the views so
/// the rules can be tested without a running app.
enum PanelPlacement {
    /// The one answer to "which screen is this window on", shared by first-time
    /// placement and by ongoing clamping. Two different answers would let a
    /// window be anchored against one display and then clamped against another.
    ///
    /// `NSWindow.screen` is nil whenever the window is off-screen — which
    /// includes every closed window, so a reopen must not depend on it. Fall
    /// back to the display the window's own frame sits on, which is the one the
    /// user parked it on; only when that fails too does the cursor decide.
    /// `NSScreen.main` is last because for a menu-bar-only app it means
    /// whichever screen holds the key window, which need not be either.
    @MainActor static func screen(for window: NSWindow) -> NSScreen? {
        if let onScreen = window.screen { return onScreen }
        let screens = NSScreen.screens
        if let index = screenIndex(for: window.frame, in: screens.map(\.frame)) {
            return screens[index]
        }
        return screenUnderCursor() ?? NSScreen.main ?? screens.first
    }

    /// The display a frame belongs to: the one it overlaps most, so a window
    /// straddling two screens resolves the way AppKit would rather than by
    /// whichever screen is listed first.
    static func screenIndex(for frame: CGRect, in screens: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, screen) in screens.enumerated() {
            let overlap = screen.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            guard area > 0 else { continue }
            if best == nil || area > best!.area { best = (index, area) }
        }
        return best?.index
    }

    /// Where a window should open when it has no meaningful frame yet.
    @MainActor static func screenUnderCursor() -> NSScreen? {
        let cursor = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(cursor) }
    }

    /// Gap between the panel and the screen edges it is anchored to.
    static let inset: CGFloat = 16
    /// Gap below the menu bar.
    static let topInset: CGFloat = 8
    static let minWidth: CGFloat = 400

    /// The panel's resting place the first time it opens: under the menu bar,
    /// against the right edge, near the status item it belongs to.
    static func anchored(_ frame: CGRect, in visible: CGRect) -> CGRect {
        var result = sized(frame, in: visible)
        result.origin = CGPoint(x: visible.maxX - result.width - inset,
                                y: visible.maxY - result.height - topInset)
        return clamped(result, in: visible)
    }

    /// Pulls a frame back inside the usable area without moving it further than
    /// it has to. Used on every open, resize, and move, because a window keeps
    /// its bottom-left corner when it grows — so a taller inbox pushes its own
    /// title bar up under the menu bar and eventually off-screen.
    ///
    /// Never widens: it also runs against the menu-bar popover, whose width is
    /// SwiftUI's business. It only shrinks what could not otherwise fit.
    static func clamped(_ frame: CGRect, in visible: CGRect) -> CGRect {
        var result = frame
        result.size.width = min(frame.width, visible.width)
        result.size.height = min(frame.height, visible.height)
        // `max(..., visible.minX)` matters when the panel is larger than the
        // screen: there is no fully in-bounds origin, so pin the top-left
        // corner and let the overflow fall off the far edge, where it costs
        // the user nothing they can't scroll to.
        result.origin.x = min(max(result.minX, visible.minX),
                              max(visible.maxX - result.width, visible.minX))
        result.origin.y = min(max(result.minY, visible.minY),
                              max(visible.maxY - result.height, visible.minY))
        return result
    }

    private static func sized(_ frame: CGRect, in visible: CGRect) -> CGRect {
        var result = frame
        result.size.width = min(max(frame.width, minWidth), visible.width)
        result.size.height = min(frame.height, visible.height)
        return result
    }
}
