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
        case "claude": return Color(red: 0.851, green: 0.467, blue: 0.341) // Claude terracotta
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

/// Claude's spark mark: eight round-capped arms radiating from the centre,
/// long and short alternating — the shape of the real logo, drawn as a path
/// so it stays crisp at any size.
struct ClaudeSparkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let arms = 8
        for i in 0..<arms {
            let angle = (CGFloat(i) / CGFloat(arms)) * 2 * .pi - .pi / 2
            let length = radius * (i.isMultiple(of: 2) ? 1.0 : 0.68)
            path.move(to: center)
            path.addLine(to: CGPoint(x: center.x + cos(angle) * length,
                                     y: center.y + sin(angle) * length))
        }
        return path
    }
}

/// Small rounded-square glyph identifying the agent, used on cards and rows.
struct AgentGlyph: View {
    let kind: AgentKind
    var size: CGFloat = 22

    var body: some View {
        if kind.rawValue == "claude", let logo = Self.claudeLogo {
            Image(nsImage: logo)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(colors: [Theme.agentColor(kind).opacity(0.95),
                                            Theme.agentColor(kind).opacity(0.70)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: size, height: size)
                .overlay(symbol)
        }
    }

    /// The bundled Claude logo; the drawn spark below is the fallback when
    /// running unbundled (e.g. straight from `swift run`).
    static let claudeLogo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "claude", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    @ViewBuilder private var symbol: some View {
        if kind.rawValue == "claude" {
            ClaudeSparkShape()
                .stroke(style: StrokeStyle(lineWidth: size * 0.13, lineCap: .round))
                .foregroundStyle(.white)
                .padding(size * 0.22)
        } else {
            Image(systemName: Theme.agentSymbol(kind))
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
        }
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
