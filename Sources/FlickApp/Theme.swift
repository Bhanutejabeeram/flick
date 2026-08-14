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

    // MARK: - Shared metrics

    /// Two alignment rails, and nothing between them.
    ///
    /// `gutter` is the left edge of every structural element — cards, row
    /// backgrounds, section headings, the footer. `boxInset` is the padding
    /// inside those boxes, so all *content* lines up on a second rail at
    /// `gutter + boxInset`. Every padding value in the popover is one of these
    /// two; the drifting 7/9/13/14/16 mix that came before is what made things
    /// look a pixel off without it being obvious why.
    static let gutter: CGFloat = 14
    static let boxInset: CGFloat = 12

    static let cardCorner: CGFloat = 12
    /// Buttons and small controls. Soft, but a rectangle rather than a pill —
    /// capsules at this size read as decoration.
    static let controlCorner: CGFloat = 7
    static let popoverWidth: CGFloat = 400

    // MARK: - Risk

    /// Risk is the one place colour survives, and only at the top of the scale.
    ///
    /// Everything else in the popover is monochrome, which is precisely what
    /// makes this readable: if something is red, it is destructive. Low and
    /// medium carry no colour at all, because a UI where three things glow is a
    /// UI where none of them mean anything.
    static func riskColor(_ risk: RiskLevel) -> Color {
        switch risk {
        case .low, .medium: return .secondary
        case .high: return .red
        }
    }
}

/// A quiet left-to-right sheen that loops while a session is working.
///
/// This is how a working session announces itself now that the status dots are
/// gone: motion means running, stillness means stopped, and it reads from the
/// corner of the eye without a single colour being involved.
///
/// The lifecycle here is the whole point, and getting it wrong crashed the app
/// once already. A `repeatForever` animation keeps driving updates into its
/// hosting view for as long as it runs, and a menu-bar popover's window is torn
/// down the moment the popover closes. Left running, the animation asks a
/// window that is going away to update its constraints, AppKit raises, and the
/// uncaught exception takes the status item down with it — the process survives
/// but the icon vanishes. So: it starts on appear, it stops on disappear, and
/// it never restarts itself while off screen.
struct ShimmerText: View {
    let text: String
    var font: Font = .system(size: 11)
    /// Still text for anything that is not moving, so the effect is never
    /// merely decorative.
    var animated: Bool = true

    @State private var sweeping = false
    @State private var onScreen = false

    private var running: Bool { animated && onScreen && sweeping }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(.secondary)
            .overlay { if running { sheen } }
            .onAppear { onScreen = true; sync() }
            .onDisappear { onScreen = false; stop() }
            .onChange(of: animated) { _, _ in sync() }
    }

    private func sync() { animated && onScreen ? start() : stop() }

    private func start() {
        guard !sweeping else { return }   // never stack a second loop
        sweeping = true
    }

    private func stop() {
        sweeping = false
    }

    /// The sweep itself. Its animation is attached to this subview rather than
    /// started imperatively, so tearing the subview down takes the animation
    /// with it instead of leaving it running against a dead window.
    private var sheen: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 2.2) / 2.2

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color.primary.opacity(0.9), location: 0.5),
                    .init(color: .clear, location: 1),
                ],
                startPoint: UnitPoint(x: t * 2.2 - 1.1, y: 0.5),
                endPoint: UnitPoint(x: t * 2.2 - 0.5, y: 0.5))
        }
        .mask(Text(text).font(font))
        .allowsHitTesting(false)
    }
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

/// The popover's only button.
///
/// One accent colour throughout, with emphasis carried by fill rather than by
/// hue — a filled button, a tinted one, and a bare one. Colour-coding each
/// action separately (a blue Allow beside a red Deny beside a grey third
/// option) is what made the row look like a toy.
struct ActionButton: View {
    enum Kind {
        /// The action you most likely want. Solid accent.
        case primary
        /// Everything else with a background. Tinted accent.
        case secondary
        /// Text only, for the way out.
        case quiet
    }

    let title: String
    let kind: Kind
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: kind == .primary ? .semibold : .medium))
                .padding(.horizontal, kind == .quiet ? 8 : 12)
                .padding(.vertical, 5.5)
                .background(background,
                            in: RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous))
                .foregroundStyle(foreground)
                .contentShape(RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var background: Color {
        switch kind {
        case .primary: return Color.accentColor.opacity(hovering ? 1 : 0.88)
        case .secondary: return Color.accentColor.opacity(hovering ? 0.20 : 0.12)
        case .quiet: return Color.accentColor.opacity(hovering ? 0.10 : 0)
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return .accentColor
        case .quiet: return hovering ? .accentColor : .secondary
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
