import AppKit
import InboxCore
import SwiftUI

struct InboxView: View {
    @EnvironmentObject private var broker: Broker
    @ObservedObject private var prefs = Preferences.shared
    @State private var showSettings = false
    @State private var cardsHeight: CGFloat = 0

    private struct CardsHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if broker.pending.isEmpty {
                emptyState
            } else {
                // The scroll area hugs its content up to a cap; a bare
                // maxHeight let SwiftUI collapse it and clip the cards.
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(broker.pending) { item in
                            RequestCard(
                                item: item,
                                onDecide: { decision, reply in
                                    broker.resolve(id: item.id, decision: decision, reply: reply)
                                },
                                onJump: { SessionFocus.focus(item.request.origin) })
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                    .padding(.bottom, Theme.gutter)
                    .padding(.top, 4)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: CardsHeightKey.self,
                                                   value: proxy.size.height)
                        }
                    )
                }
                .onPreferenceChange(CardsHeightKey.self) { cardsHeight = $0 }
                .frame(height: min(max(cardsHeight, 120), 460))
            }

            if !broker.agentRows.isEmpty {
                AgentStatusDashboard()
            }

            if let error = broker.lastError {
                errorBanner(error)
            }

            if showSettings {
                settingsPanel
            }

            footer
        }
        .frame(width: Theme.popoverWidth)
        // Translucent HUD material, like the system menu-bar panels.
        .background(VisualEffectBackground().ignoresSafeArea())
        // Keeps whichever window is hosting this view on screen — see
        // WindowClamper for why the popover in particular needs it.
        .background(WindowClamper())
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 7) {
            Text("Flick")
                .font(.system(size: 14, weight: .semibold))

            if broker.badgeCount > 0 {
                Text("\(broker.badgeCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.accentColor,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .foregroundStyle(.white)
            }

            Spacer()

            // Silent when healthy; only surfaces when the socket is down.
            if !broker.isListening {
                Text("Offline")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("Flick is not listening on its socket — agents cannot reach it.")
            }
        }
        .padding(.horizontal, Theme.gutter + Theme.boxInset)
        .padding(.top, 13)
        .padding(.bottom, broker.pending.isEmpty ? 0 : 10)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 5) {
            Text("All clear")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Text(broker.sessions.isEmpty
                 ? "Requests from your agents will show up here."
                 : "\(broker.sessions.count) session\(broker.sessions.count == 1 ? "" : "s") running. Nothing needs you.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
        .padding(.bottom, 28)
        .padding(.horizontal, Theme.gutter + Theme.boxInset)
    }

    // MARK: - Error

    /// Text only, on the same rail as everything else. The old warning triangle
    /// was a second colour saying what the sentence already said.
    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.gutter + Theme.boxInset)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05))
    }

    // MARK: - Settings

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Hairline()
                .padding(.bottom, 4)

            Toggle("Notifications", isOn: Binding(
                get: { prefs.notificationsEnabled },
                set: { prefs.notificationsEnabled = $0 }))
            Toggle("Sound", isOn: Binding(
                get: { prefs.soundEnabled },
                set: { prefs.soundEnabled = $0 }))
            Toggle("Launch at login", isOn: Binding(
                get: { prefs.launchAtLogin },
                set: { prefs.launchAtLogin = $0 }))
            if let error = prefs.launchAtLoginError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if broker.sessionAllowCount > 0 {
                Button(broker.sessionAllowCount == 1
                       ? "Ask me again (1 session is auto-approved)"
                       : "Ask me again (\(broker.sessionAllowCount) sessions are auto-approved)") {
                    broker.clearSessionAllowlist()
                }
                .controlSize(.small)
                .help("You chose “Allow for session” earlier, so safe commands run without asking. Click to turn that off and be asked every time again.")
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 11.5))
        .padding(.horizontal, Theme.gutter + Theme.boxInset)
        .padding(.bottom, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack {
                FooterIconButton(symbol: "gearshape", help: "Settings") {
                    withAnimation(.easeOut(duration: 0.15)) { showSettings.toggle() }
                }
                Spacer()
                ActionButton(title: "Quit", kind: .quiet) { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: [.command])
            }
            // The gear sits at the structural rail; its 22pt box carries the
            // rest of the inset so the icon centres over the content rail.
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 7)
        }
    }
}

/// Small icon button used in the footer.
private struct FooterIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .background(hovering ? Color.primary.opacity(0.07) : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
