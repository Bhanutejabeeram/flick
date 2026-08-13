import InboxCore
import SwiftUI

/// One waiting agent, rendered as an approval card.
///
/// The exact command is always shown verbatim and is never truncated away
/// behind a summary — approving something you cannot see is the failure mode
/// this whole product exists to avoid.
struct RequestCard: View {
    let item: PendingItem
    let onDecide: (InboxDecision, String?) -> Void
    let onJump: () -> Void

    @State private var replyText = ""
    @State private var showDetail = false
    @FocusState private var replyFocused: Bool

    private var request: InboxRequest { item.request }
    private var agentColor: Color { Theme.agentColor(request.agent) }
    private var riskColor: Color { Theme.riskColor(request.risk) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            messageBlock
            if let detail = request.detail, !detail.isEmpty {
                detailDisclosure(detail)
            }
            actionRow
            if request.actions.contains(.reply) || request.type == .question {
                replyRow
            }
        }
        .padding(13)
        // Flat translucent tint over the blurred material — no shadows, no
        // opaque chrome; the hairline is what separates card from ground.
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(
                    request.risk == .high
                        ? AnyShapeStyle(Color.red.opacity(0.45))
                        : AnyShapeStyle(Color.primary.opacity(0.09)),
                    lineWidth: request.risk == .high ? 1.5 : 1)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            AgentGlyph(kind: request.agent)

            VStack(alignment: .leading, spacing: 1) {
                Text(request.agent.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                Button(action: onJump) {
                    HStack(spacing: 3) {
                        Text(request.project)
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Jump to this session — \(request.cwd)")
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                if request.risk >= .medium {
                    Text(request.risk.label.uppercased())
                        .font(.system(size: 8.5, weight: .heavy))
                        .tracking(0.4)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(riskColor.opacity(0.14), in: Capsule())
                        .foregroundStyle(riskColor)
                }
                if let expiresAt = item.expiresAt {
                    // TimelineView keeps the repaint local to this label.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(expiresAt.timeIntervalSince(context.date)))
                        Label(countdownLabel(seconds), systemImage: "clock")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .help("Falls back to the terminal prompt when this runs out.")
                }
            }
        }
    }

    // MARK: - Message

    private var messageBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(promptLine)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.3)

            Text(request.message)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                )
        }
    }

    private var promptLine: String {
        switch request.type {
        case .approval: return "wants to run · \(request.title)"
        case .question: return request.title.isEmpty ? "asked you" : request.title
        case .error: return "error"
        default: return request.title
        }
    }

    private func detailDisclosure(_ detail: String) -> some View {
        DisclosureGroup(isExpanded: $showDetail) {
            ScrollView {
                Text(detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 150)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } label: {
            Text("Full request")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .disclosureGroupStyle(.automatic)
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 7) {
            if request.actions.contains(.deny) {
                ActionButton(title: "Deny", kind: .destructive) { onDecide(.deny, nil) }
                    .keyboardShortcut("d", modifiers: [.command])
            }
            if request.actions.contains(.allow) {
                // Cmd-Return, not bare Return: a bare Return key equivalent
                // fires ahead of the reply field's onSubmit, so typing a reply
                // and pressing Return would approve the command instead.
                ActionButton(title: "Allow once", kind: .primary) { onDecide(.allow, nil) }
                    .keyboardShortcut(.return, modifiers: [.command])
            }
            if request.actions.contains(.allowSession) && request.risk < .high {
                ActionButton(title: "Allow for session", kind: .neutral) { onDecide(.allowSession, nil) }
                    .help("Auto-approve further non-destructive requests from this session")
            }
            Spacer(minLength: 0)
            if request.blocking {
                ActionButton(title: "Not now", kind: .quiet) { onDecide(.defer_, nil) }
                    .help("Leave it to the normal prompt in the terminal")
            }
        }
    }

    private var replyRow: some View {
        HStack(spacing: 6) {
            TextField("Reply instead…", text: $replyText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .focused($replyFocused)
                .onSubmit(sendReply)

            Button(action: sendReply) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 21))
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
    }

    private var canSend: Bool {
        !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onDecide(.reply, text)
        replyText = ""
    }

    private func countdownLabel(_ seconds: Int) -> String {
        seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}
