import AppKit
import InboxCore
import SwiftUI

@main
struct FlickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var broker = Broker.shared

    var body: some Scene {
        MenuBarExtra {
            InboxView()
                .environmentObject(broker)
        } label: {
            MenuBarLabel(count: broker.badgeCount,
                         risk: broker.highestPendingRisk,
                         listening: broker.isListening)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu-bar glyph. It has to answer "does anything need me?" from the
/// corner of the eye, so the count rides next to the icon and the icon itself
/// changes when something destructive is waiting.
struct MenuBarLabel: View {
    let count: Int
    let risk: RiskLevel?
    let listening: Bool

    var body: some View {
        HStack(spacing: 3) {
            icon
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
    }

    @ViewBuilder private var icon: some View {
        if let logo = Self.logo {
            // Dimmed when the socket is down: the mark is still recognisably
            // Flick, but clearly "off".
            Image(nsImage: logo).opacity(listening ? 1 : 0.35)
        } else {
            Image(systemName: symbolName)
        }
    }

    /// The bundled monochrome logo. Template mode lets macOS recolor it for
    /// light/dark menu bars and the pressed state.
    static let logo: NSImage? = {
        guard let image = NSImage(named: "MenuIcon") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    private var symbolName: String {
        if !listening { return "bolt.slash" }
        return count == 0 ? "bolt" : "bolt.fill"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var inboxPanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            Broker.shared.start()
            Preferences.shared.applyDefaultLaunchAtLogin()
        }
        // Tapping a notification banner cannot open a MenuBarExtra popover
        // (there is no public API for that), so it opens this floating panel
        // with the same inbox instead of silently doing nothing.
        NotificationCenter.default.addObserver(
            forName: .openInbox, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showInboxPanel() }
        }
    }

    @MainActor private func showInboxPanel() {
        // First open is exactly "no panel yet" — deriving it beats a second
        // stored flag that has to be kept in sync with the panel's lifetime.
        let firstOpen = inboxPanel == nil
        let panel = inboxPanel ?? makeInboxPanel()
        inboxPanel = panel
        place(panel, firstOpen: firstOpen)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor private func makeInboxPanel() -> NSPanel {
        let host = NSHostingController(rootView: InboxView().environmentObject(Broker.shared))
        let panel = NSPanel(contentViewController: host)
        panel.styleMask = [.titled, .closable, .fullSizeContentView, .utilityWindow]
        panel.title = "Flick"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        // Ongoing resizes and moves are handled by the WindowClamper riding
        // inside InboxView, which covers this panel and the menu-bar popover
        // alike.
        return panel
    }

    /// Puts the panel where it belongs before it is shown.
    ///
    /// On first open it is anchored under the menu bar on the right, near the
    /// status item it belongs to. After that its position is the user's — a
    /// reopen only pulls it back if it has drifted out of view, which happens
    /// when the display it was on goes away.
    @MainActor private func place(_ panel: NSPanel, firstOpen: Bool) {
        // Lay out first. Reading the size before this gives the placeholder
        // frame, which is what put the panel in the wrong spot to begin with.
        panel.layoutIfNeeded()
        // A brand-new panel sits at AppKit's default frame on the primary
        // display, so its own frame cannot say which screen the user means.
        let screen = firstOpen
            ? (PanelPlacement.screenUnderCursor() ?? PanelPlacement.screen(for: panel))
            : PanelPlacement.screen(for: panel)
        guard let visible = screen?.visibleFrame else { return }
        let frame = firstOpen
            ? PanelPlacement.anchored(panel.frame, in: visible)
            : PanelPlacement.clamped(panel.frame, in: visible)
        guard !frame.equalTo(panel.frame) else { return }
        panel.setFrame(frame, display: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            Broker.shared.stop()
        }
    }
}
