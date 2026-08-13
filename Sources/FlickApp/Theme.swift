import AppKit
import InboxCore
import SwiftUI

/// Vibrant blurred background for the popover, same material as the system
/// menu-bar HUDs. The hosting window is made non-opaque so the desktop
/// actually bleeds through the blur.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }
}

/// One place for the popover's visual language, so cards, rows, and banners
/// stay consistent as adapters multiply.
enum Theme {
    // MARK: - Agent identity

    static func agentColor(_ kind: AgentKind) -> Color {
        switch kind.rawValue {
        case "claude": return Color(red: 0.85, green: 0.45, blue: 0.30)   // coral
        case "codex": return Color(red: 0.25, green: 0.65, blue: 0.60)    // teal
        case "gemini": return Color(red: 0.35, green: 0.52, blue: 0.95)   // blue
        case "opencode": return Color(red: 0.55, green: 0.45, blue: 0.90) // violet
        default: return Color(white: 0.55)
        }
    }

    static func agentSymbol(_ kind: AgentKind) -> String {
        switch kind.rawValue {
        case "claude": return "asterisk"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "gemini": return "sparkle"
        default: return "terminal"
        }
    }

    static func riskColor(_ risk: RiskLevel) -> Color {
        switch risk {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }

    // MARK: - Shared metrics

    static let cardCorner: CGFloat = 12
    static let popoverWidth: CGFloat = 400
}

/// Small rounded-square glyph identifying the agent, used on cards and rows.
struct AgentGlyph: View {
    let kind: AgentKind
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(
                LinearGradient(colors: [Theme.agentColor(kind).opacity(0.95),
                                        Theme.agentColor(kind).opacity(0.70)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: Theme.agentSymbol(kind))
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}

/// Capsule action button with a hover state; macOS's stock bordered buttons
/// look out of place in a menu-bar popover.
struct ActionButton: View {
    enum Kind {
        case primary      // Allow — filled accent
        case destructive  // Deny — red tint
        case neutral      // Allow for session, etc.
        case quiet        // Not now
    }

    let title: String
    let kind: Kind
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: kind == .primary ? .semibold : .medium))
                .padding(.horizontal, kind == .quiet ? 6 : 11)
                .padding(.vertical, 5)
                .background(background, in: Capsule())
                .foregroundStyle(foreground)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var background: Color {
        switch kind {
        case .primary: return hovering ? Color.accentColor : Color.accentColor.opacity(0.85)
        case .destructive: return Color.red.opacity(hovering ? 0.22 : 0.13)
        case .neutral: return Color.primary.opacity(hovering ? 0.14 : 0.08)
        case .quiet: return hovering ? Color.primary.opacity(0.07) : .clear
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .destructive: return .red
        case .neutral: return .primary
        case .quiet: return .secondary
        }
    }
}

/// Hairline divider that stays subtle in both light and dark appearance.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
    }
}
