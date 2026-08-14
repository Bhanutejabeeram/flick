import Foundation

/// What an agent session is doing right now.
public enum SessionActivity: String, Codable, Sendable, Hashable {
    /// The agent is running. Nothing is expected of the user.
    case working
    /// The agent stopped and cannot continue without the user.
    case waiting
    /// The agent's turn ended, or the session went away.
    case finished
    /// The agent stopped on something that went wrong.
    case error

    public var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Waiting"
        case .finished: return "Finished"
        case .error: return "Error"
        }
    }

    /// Whether this state is the user's problem to solve.
    public var needsUser: Bool {
        switch self {
        case .waiting, .error: return true
        case .working, .finished: return false
        }
    }

    /// Dashboard order, lowest first: whatever has stopped for the user rises
    /// above whatever is happily running.
    public var sortPriority: Int {
        switch self {
        case .waiting: return 0
        case .error: return 1
        case .working: return 2
        case .finished: return 3
        }
    }
}

/// A session's activity plus when it entered it, which is what makes
/// "Working · 4m 12s" possible.
///
/// `since` is the moment of the *transition*, not the last event: a session
/// that has been working for four minutes should keep counting up rather than
/// resetting every time another tool call goes by.
public struct SessionStatus: Hashable, Sendable {
    public var activity: SessionActivity
    /// A more specific phrase than the bare activity label, when the event
    /// carried one — "Waiting for approval" beats "Waiting".
    public var detail: String?
    public var since: Date

    public init(_ activity: SessionActivity, detail: String? = nil, since: Date = Date()) {
        self.activity = activity
        self.detail = detail
        self.since = since
    }

    /// What the row actually prints.
    public var label: String { detail ?? activity.label }

    public func duration(asOf now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(since))
    }

    // MARK: - Transitions

    /// The status a session moves into when one of its events arrives, or nil
    /// when the event says nothing about what the agent is doing.
    ///
    /// `awaitingUser` is the caller's answer to "did this event actually end up
    /// as a card someone has to answer?" — it cannot be read off the request
    /// alone. An approval that a session-wide allow or a terminal-only setting
    /// answers on the spot never stops the agent, so reporting it as
    /// ``SessionActivity/waiting`` would show a session as blocked when it is
    /// running perfectly well.
    public static func transition(for request: InboxRequest,
                                  awaitingUser: Bool,
                                  now: Date = Date()) -> SessionStatus? {
        switch request.type {
        case .sessionStart:
            return SessionStatus(.working, since: now)
        case .sessionEnd:
            return SessionStatus(.finished, since: now)
        case .finished:
            return SessionStatus(.finished, since: now)
        case .error:
            return SessionStatus(.error, since: now)
        case .approval, .question:
            guard awaitingUser else {
                // Answered without troubling the user, so the agent carried
                // straight on.
                return SessionStatus(.working, since: now)
            }
            return SessionStatus(.waiting, detail: waitDetail(for: request), since: now)
        }
    }

    /// The phrase shown while a card is up. Approvals are always the same
    /// question; the adapter already writes a good headline for everything else
    /// ("Waiting for permission", "Needs input"), so that is reused verbatim
    /// rather than flattened into a generic label.
    private static func waitDetail(for request: InboxRequest) -> String {
        if request.type == .approval { return "Waiting for approval" }
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Waiting for you" : title
    }

    /// Whether `new` is worth replacing `self` with.
    ///
    /// Repeat events of the same kind must not restart the clock — a session
    /// that has been waiting 38 seconds is still 38 seconds in when a duplicate
    /// notification lands, and a timer that keeps resetting to zero is worse
    /// than no timer at all.
    public func supersedes(_ new: SessionStatus) -> Bool {
        activity == new.activity && detail == new.detail
    }
}

/// Compact elapsed-time labels for the dashboard: `38s`, `4m 12s`, `1h 4m`.
///
/// Seconds are dropped past the hour on purpose. Past that point the exact
/// second is noise, and a label that changes width every tick makes the whole
/// row jitter.
public enum DurationLabel {
    public static func compact(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }
}
