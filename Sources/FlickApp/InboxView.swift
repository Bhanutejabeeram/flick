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
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
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

            if !broker.sessions.isEmpty {
                sessionSection
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
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Flick")
                .font(.system(size: 15, weight: .bold))

            if broker.badgeCount > 0 {
                Text("\(broker.badgeCount)")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }

            Spacer()

            // Silent when healthy; only surfaces when the socket is down.
            if !broker.isListening {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                    Text("Offline")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, broker.pending.isEmpty ? 0 : 10)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 6)

            Text("All clear")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            Text(broker.sessions.isEmpty
                 ? "Waiting requests from your agents will show up here."
                 : "\(broker.sessions.count) session\(broker.sessions.count == 1 ? "" : "s") running. Nothing needs you.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.bottom, 30)
        .padding(.horizontal, 24)
    }

    // MARK: - Sessions

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Hairline()
                .padding(.bottom, 8)

            Text("Sessions")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.bottom, 4)

            ForEach(broker.sessions.prefix(6)) { session in
                SessionRow(session: session)
            }
        }
        .padding(.horizontal, 7)
        .padding(.bottom, 8)
    }

    // MARK: - Error

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(message)
                .font(.system(size: 10.5))
                .lineLimit(2)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
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
                    .foregroundStyle(.orange)
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
        .padding(.horizontal, 16)
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
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("q", modifiers: [.command])
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

/// One running session, with hover highlight and jump-on-click. Right-click
/// to shift its approvals to the terminal and back.
private struct SessionRow: View {
    let session: SessionRecord
    @EnvironmentObject private var broker: Broker
    @State private var hovering = false

    private var inTerminal: Bool { broker.terminalOnly.contains(session.id) }

    var body: some View {
        Button {
            SessionFocus.focus(session.origin)
        } label: {
            HStack(spacing: 8) {
                AgentGlyph(kind: session.agent, size: 17)
                Text(session.agent.displayName)
                    .font(.system(size: 11.5, weight: .medium))
                Text(session.project)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                if inTerminal {
                    Label("in editor", systemImage: "terminal")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .help("Approvals go to the editor's own prompt. Right-click to bring them back.")
                }
                Spacer()
                if hovering {
                    Button {
                        broker.setTerminalOnly(session.id, !inTerminal)
                    } label: {
                        Image(systemName: inTerminal ? "bell.slash.fill" : "terminal")
                            .font(.system(size: 10))
                            .foregroundStyle(inTerminal ? .primary : .secondary)
                            .frame(width: 20, height: 20)
                            .background(Color.primary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(inTerminal ? "Bring approvals back to Flick"
                                     : "Answer this session's approvals in the editor only")
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(relative(session.lastSeen))
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5.5)
            .background(hovering ? Color.primary.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(session.cwd)
    }

    private func relative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
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
