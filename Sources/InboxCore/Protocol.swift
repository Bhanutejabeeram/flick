import Foundation

public enum InboxProtocol {
    public static let version = 1
}

/// Which agent produced an event. Open-ended on purpose: adapters for agents we
/// have not written yet can send their own identifier and still show up.
public struct AgentKind: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let claude = AgentKind("claude")
    public static let codex = AgentKind("codex")
    public static let other = AgentKind("other")

    public var displayName: String {
        switch rawValue {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "gemini": return "Gemini CLI"
        case "opencode": return "OpenCode"
        case "cursor": return "Cursor"
        default: return rawValue.capitalized
        }
    }
}

public enum RequestType: String, Codable, Sendable {
    /// The agent wants to run a tool/command and needs a decision.
    case approval
    /// The agent asked the user something and is waiting on free text.
    case question
    /// The agent finished its turn and is idle.
    case finished
    /// The agent hit an error worth surfacing.
    case error
    /// Bookkeeping only: a session appeared or went away.
    case sessionStart = "session_start"
    case sessionEnd = "session_end"

    /// Bookkeeping events never appear as inbox cards.
    public var isActionable: Bool {
        switch self {
        case .approval, .question: return true
        case .finished, .error, .sessionStart, .sessionEnd: return false
        }
    }
}

public enum InboxAction: String, Codable, Sendable, CaseIterable {
    case allow
    case allowSession = "allow_session"
    case deny
    case reply
    /// Hand the decision back to the agent's own UI (the normal terminal prompt).
    case defer_ = "defer"
}

public enum RiskLevel: String, Codable, Sendable, Comparable {
    case low, medium, high

    private var order: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }
    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.order < rhs.order }

    public var label: String {
        switch self {
        case .low: return "Low risk"
        case .medium: return "Review"
        case .high: return "Destructive"
        }
    }
}

/// Where the originating session lives, so the app can jump back to it.
public struct SessionOrigin: Codable, Hashable, Sendable {
    public var tty: String?
    public var pid: Int32?
    /// p_comm of the process `pid` referred to when captured. Liveness checks
    /// compare it so a recycled pid is not mistaken for the original process.
    public var processName: String?
    public var termProgram: String?
    public var bundleIdentifier: String?

    public init(tty: String? = nil, pid: Int32? = nil, processName: String? = nil,
                termProgram: String? = nil, bundleIdentifier: String? = nil) {
        self.tty = tty
        self.pid = pid
        self.processName = processName
        self.termProgram = termProgram
        self.bundleIdentifier = bundleIdentifier
    }

    /// Reads the terminal identity of the current process. Adapters call this
    /// so the app can focus the right window later.
    ///
    /// A hook helper is started with pipes for stdio, so probing our own
    /// descriptors with `ttyname()` finds nothing — the answer has to come from
    /// the process tree above us.
    public static func current() -> SessionOrigin {
        let env = ProcessInfo.processInfo.environment

        let tty: String?
        if let override = env["FLICK_TTY"], !override.isEmpty {
            tty = override
        } else if isatty(0) == 1, let name = ttyname(0) {
            tty = String(cString: name)
        } else {
            tty = ProcessTree.controllingTTY()
        }

        let termProgram = env["TERM_PROGRAM"]
        var bundle: String?
        switch termProgram {
        case "vscode": bundle = env["TERM_PROGRAM_VERSION"]?.contains("insider") == true
            ? "com.microsoft.VSCodeInsiders" : "com.microsoft.VSCode"
        case "Apple_Terminal": bundle = "com.apple.Terminal"
        case "iTerm.app": bundle = "com.googlecode.iterm2"
        case "ghostty": bundle = "com.mitchellh.ghostty"
        case "WarpTerminal": bundle = "dev.warp.Warp-Stable"
        case "Hyper": bundle = "co.zeit.hyper"
        case "WezTerm": bundle = "com.github.wez.wezterm"
        default: bundle = nil
        }
        if bundle == nil { bundle = ProcessTree.terminalBundleID() }

        // Report the agent's pid rather than the short-lived helper's, so the
        // app can still find the process after the hook exits. nil when no
        // plausible owner is found — the app then falls back to recency-based
        // liveness, which beats declaring a live session dead. The name rides
        // along so a recycled pid can be told apart from the original process.
        let owner = ProcessTree.owningProcess()

        return SessionOrigin(tty: tty, pid: owner?.pid, processName: owner?.name,
                             termProgram: termProgram, bundleIdentifier: bundle)
    }
}

/// How to reach a session when no hook is currently blocking on us.
///
/// Claude Code exports a per-session messaging socket plus an auth token into
/// the hook environment. Capturing them lets the app push a typed reply into a
/// session that is merely idle, instead of only answering blocked tool calls.
public struct ResponseChannel: Codable, Hashable, Sendable {
    /// "blocking" (an adapter is holding a connection open) or "messaging"
    /// (fire a message at the agent's own inbox socket).
    public var kind: String
    public var socketPath: String?
    public var token: String?

    public init(kind: String, socketPath: String? = nil, token: String? = nil) {
        self.kind = kind
        self.socketPath = socketPath
        self.token = token
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case socketPath = "socket_path"
        case token
    }

    /// Reads Claude Code's cross-session messaging environment, when present.
    public static func fromEnvironment() -> ResponseChannel? {
        let env = ProcessInfo.processInfo.environment
        guard let socket = env["CLAUDE_CODE_MESSAGING_SOCKET"], !socket.isEmpty else { return nil }
        return ResponseChannel(kind: "messaging", socketPath: socket,
                               token: env["CLAUDE_CODE_MESSAGING_TOKEN"])
    }
}

/// The canonical internal event. Every adapter translates into exactly this, so
/// the broker and UI never learn agent-specific vocabulary.
public struct InboxRequest: Codable, Identifiable, Hashable, Sendable {
    public var v: Int = InboxProtocol.version
    public var id: String
    public var agent: AgentKind
    public var sessionID: String
    public var project: String
    public var cwd: String
    public var type: RequestType
    /// Short headline, e.g. the tool name.
    public var title: String
    /// Human-readable request, e.g. the exact command.
    public var message: String
    /// Full payload shown behind a disclosure, e.g. pretty-printed tool input.
    public var detail: String?
    public var actions: [InboxAction]
    public var risk: RiskLevel
    /// True when the adapter is holding the connection open for a decision.
    /// False for fire-and-forget notifications.
    public var blocking: Bool
    /// How long the adapter is willing to wait before it gives up.
    public var timeoutMS: Int
    public var origin: SessionOrigin
    /// Out-of-band way to reach the session; nil when the only channel is the
    /// open connection this request arrived on.
    public var channel: ResponseChannel?
    public var createdAt: Date

    public init(id: String = UUID().uuidString,
                agent: AgentKind,
                sessionID: String,
                project: String,
                cwd: String,
                type: RequestType,
                title: String,
                message: String,
                detail: String? = nil,
                actions: [InboxAction] = [],
                risk: RiskLevel = .low,
                blocking: Bool = false,
                timeoutMS: Int = 0,
                origin: SessionOrigin = SessionOrigin(),
                channel: ResponseChannel? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.agent = agent
        self.sessionID = sessionID
        self.project = project
        self.cwd = cwd
        self.type = type
        self.title = title
        self.message = message
        self.detail = detail
        self.actions = actions
        self.risk = risk
        self.blocking = blocking
        self.timeoutMS = timeoutMS
        self.origin = origin
        self.channel = channel
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case v, id, agent, type, title, message, detail, actions, risk, blocking, origin, project, cwd, channel
        case sessionID = "session_id"
        case timeoutMS = "timeout_ms"
        case createdAt = "created_at"
    }

    /// Identity used to collapse duplicate events from chatty adapters.
    public var dedupeKey: String {
        "\(agent.rawValue)|\(sessionID)|\(type.rawValue)|\(title)|\(message)"
    }
}

public enum InboxDecision: String, Codable, Sendable {
    case allow
    case allowSession = "allow_session"
    case deny
    case reply
    /// Hand back to the agent's own prompt.
    case defer_ = "defer"
    /// Nobody answered in time.
    case timeout
    /// Notification delivered; nothing to decide.
    case ack
    /// The app is not running or refused the request.
    case unavailable
}

public struct InboxResponse: Codable, Sendable {
    public var v: Int = InboxProtocol.version
    public var id: String
    public var decision: InboxDecision
    public var reply: String?
    public var reason: String?

    public init(id: String, decision: InboxDecision, reply: String? = nil, reason: String? = nil) {
        self.id = id
        self.decision = decision
        self.reply = reply
        self.reason = reason
    }
}

/// Frames on the wire. One JSON object per line, both directions.
public enum InboxFrame: Codable, Sendable {
    case request(InboxRequest)
    case response(InboxResponse)
    /// Adapter withdrew a pending request (agent died, user answered in terminal).
    case cancel(id: String)
    case ping
    case pong

    enum CodingKeys: String, CodingKey { case kind, id }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "request": self = .request(try InboxRequest(from: decoder))
        case "response": self = .response(try InboxResponse(from: decoder))
        case "cancel": self = .cancel(id: try container.decode(String.self, forKey: .id))
        case "ping": self = .ping
        case "pong": self = .pong
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                                                   debugDescription: "unknown frame kind \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .request(let r):
            try container.encode("request", forKey: .kind)
            try r.encode(to: encoder)
        case .response(let r):
            try container.encode("response", forKey: .kind)
            try r.encode(to: encoder)
        case .cancel(let id):
            try container.encode("cancel", forKey: .kind)
            try container.encode(id, forKey: .id)
        case .ping:
            try container.encode("ping", forKey: .kind)
        case .pong:
            try container.encode("pong", forKey: .kind)
        }
    }
}

public enum InboxCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}
