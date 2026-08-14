import InboxCore
import SwiftUI

/// Every agent session the app knows about, what each one is doing, and for how
/// long.
///
/// The cards above answer "what is being asked of me". This answers the other
/// half of the problem: which of your agents is running, which has stopped for
/// you, and which is already done — without going and looking at every terminal
/// window yourself.
struct AgentStatusDashboard: View {
    @EnvironmentObject private var broker: Broker

    /// Rows past this are summarised rather than drawn. A popover that runs off
    /// the bottom of the screen is worse than one that says "+3 more".
    private static let visibleLimit = 5

    var body: some View {
        let rows = broker.agentRows

        VStack(alignment: .leading, spacing: 1) {
            Hairline()
                .padding(.bottom, 9)

            header(rows: rows)

            ForEach(rows.prefix(Self.visibleLimit)) { row in
                AgentStatusRowView(row: row)
            }

            if rows.count > Self.visibleLimit {
                Text("+\(rows.count - Self.visibleLimit) more")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Theme.gutter + Theme.boxInset)
                    .padding(.top, 5)
            }
        }
        .padding(.bottom, 10)
    }

    private func header(rows: [AgentStatusRow]) -> some View {
        let waiting = rows.filter { $0.status.activity.needsUser }.count

        return HStack(spacing: 0) {
            Text("Agents")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.3)

            Spacer()

            Text(waiting > 0 ? "\(waiting) waiting" : "\(rows.count)")
                .font(.system(size: 10, weight: waiting > 0 ? .semibold : .regular))
                .foregroundStyle(waiting > 0 ? .secondary : .tertiary)
        }
        .padding(.horizontal, Theme.gutter + Theme.boxInset)
        .padding(.bottom, 6)
    }
}

/// One session: who and where on top, live status under it, and the file it has
/// its hands on at the bottom. Click to jump to the window it is running in.
private struct AgentStatusRowView: View {
    let row: AgentStatusRow
    @EnvironmentObject private var broker: Broker
    @State private var hovering = false

    private var session: SessionRecord { row.session }
    private var inTerminal: Bool { broker.terminalOnly.contains(session.id) }
    private var isWorking: Bool { row.status.activity == .working && !row.isEnded }

    var body: some View {
        Button {
            SessionFocus.focus(session.origin)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                AgentGlyph(kind: session.agent, size: 21)
                    // Optically centred on the first line of text rather than
                    // on the block, which is what "top-aligned" alone gets you.
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    identityLine
                    statusLine
                    if let target = row.target, !target.isEmpty {
                        Text(target)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                Spacer(minLength: 6)
                trailing
            }
            .padding(.horizontal, Theme.boxInset)
            .padding(.vertical, 7)
            .background(hovering ? Color.primary.opacity(0.055) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.gutter)
        // A finished session is on its way out; dimming says so without moving
        // anything, which keeps the list from twitching as rows retire.
        .opacity(row.isEnded ? 0.45 : 1)
        .onHover { hovering = $0 }
        .help(session.cwd)
    }

    // MARK: - Line one: who and where

    private var identityLine: some View {
        HStack(spacing: 5) {
            Text(session.agent.displayName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
            Text("·")
                .font(.system(size: 11.5))
                .foregroundStyle(.quaternary)
            Text(session.project)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if inTerminal {
                Text("in editor")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .help("This session's approvals go to the editor's own prompt.")
            }
        }
    }

    // MARK: - Line two: what it is doing, live

    /// Only the elapsed label sits inside the TimelineView. Wrapping the whole
    /// line meant the animated status text was rebuilt on every one-second
    /// tick, and an animation that is torn down and restarted under a view that
    /// outlives it is what took the menu-bar icon down. Invalidating the broker
    /// each second instead would re-render every card in the popover, which is
    /// why the countdown on approval cards is built the same way.
    private var statusLine: some View {
        HStack(spacing: 4) {
            ShimmerText(text: row.status.label,
                        font: .system(size: 11, weight: isWorking ? .regular : .medium),
                        animated: isWorking)

            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(.quaternary)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(DurationLabel.compact(row.status.duration(asOf: context.date)))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Trailing controls

    /// Icon-only, with the explanation on hover. An icon and its label side by
    /// side doubles the width of the row's right edge for no extra meaning.
    @ViewBuilder private var trailing: some View {
        if hovering && !row.isEnded {
            HStack(spacing: 2) {
                RowIconButton(symbol: inTerminal ? "bell.slash" : "terminal",
                              help: inTerminal ? "Bring approvals back to Flick"
                                               : "Answer this session's approvals in the editor only") {
                    broker.setTerminalOnly(session.id, !inTerminal)
                }
                RowIconButton(symbol: "arrow.up.forward", help: "Jump to this window") {
                    SessionFocus.focus(session.origin)
                }
            }
            .padding(.top, 1)
        }
    }
}

/// Small square icon button used on the right edge of a session row.
private struct RowIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 21, height: 21)
                .background(hovering ? Color.primary.opacity(0.09) : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.controlCorner - 1,
                                                 style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
