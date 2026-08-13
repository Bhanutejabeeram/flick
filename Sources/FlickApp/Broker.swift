import Foundation
import InboxCore
import SwiftUI

/// One request waiting on the user, plus the connection that will carry the
/// answer back.
struct PendingItem: Identifiable, Equatable {
    var request: InboxRequest
    /// nil for notification-only events, which nobody is blocked on.
    var connection: SocketConnection?
    var receivedAt: Date

    var id: String { request.id }

    static func == (lhs: PendingItem, rhs: PendingItem) -> Bool { lhs.id == rhs.id }

    var expiresAt: Date? {
        guard request.blocking, request.timeoutMS > 0 else { return nil }
        return receivedAt.addingTimeInterval(Double(request.timeoutMS) / 1000.0)
    }

    var secondsRemaining: Int? {
        guard let expiresAt else { return nil }
        return max(0, Int(expiresAt.timeIntervalSinceNow))
    }
}

/// Tracks sessions, pending approvals, responses, expiry, and deduplication.
@MainActor
final class Broker: ObservableObject {
    static let shared = Broker()

    @Published private(set) var pending: [PendingItem] = []
    @Published private(set) var sessions: [SessionRecord] = []
    @Published private(set) var history: [HistoryRecord] = []
    @Published private(set) var isListening = false
    @Published private(set) var lastError: String?

    /// Sessions whose approvals the user shifted back to the terminal: Flick
    /// answers their blocking requests immediately with no decision, so
    /// Claude Code shows its own prompt and no card or banner appears here.
    @Published private(set) var terminalOnly: Set<String> = []

    /// Sessions the user granted a blanket allow for this run, keyed by
    /// session id and capped at the risk level of the card the user actually
    /// clicked — a grant made on a low-risk command must not silently approve
    /// medium-risk ones later. Cleared when the session ends or the app
    /// quits — a session-scoped allow must never outlive the session.
    private var sessionAllowlist: [String: RiskLevel] = [:]

    private var server: SocketServer?
    private var store: InboxStore?
    private var expiryTimer: Timer?
    private let notifier = Notifier()

    /// Recently seen notification keys, for collapsing chatty adapters.
    private var recentNotificationKeys: [String: Date] = [:]
    private var sessionSweepCounter = 0

    var badgeCount: Int { pending.filter { $0.request.type.isActionable }.count }

    var highestPendingRisk: RiskLevel? {
        pending.filter { $0.request.type.isActionable }.map(\.request.risk).max()
    }

    // MARK: - Lifecycle

    func start() {
        do {
            store = try InboxStore()
            store?.pruneHistory()
        } catch {
            lastError = "History unavailable: \(error)"
        }

        let server = SocketServer(path: InboxPaths.socketPath) { [weak self] conn in
            // Runs on the connection's own thread.
            self?.handleConnection(conn)
        }
        do {
            try server.start()
            self.server = server
            isListening = true
            lastError = nil
        } catch {
            isListening = false
            lastError = "Could not listen on \(InboxPaths.socketPath): \(error)"
        }

        notifier.requestAuthorization()
        notifier.onAction = { [weak self] id, decision in
            Task { @MainActor in self?.resolve(id: id, decision: decision, reply: nil) }
        }
        notifier.onAuthStatus = { [weak self] granted in
            if !granted {
                self?.lastError = "Banners are off — enable Flick in System Settings → Notifications. The menu-bar badge and sound still work."
            }
        }

        refreshSessions()
        refreshHistory()

        expiryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        expiryTimer?.invalidate()
        // Release anyone still blocked so agents are not left hanging on quit.
        for item in pending where item.request.blocking {
            respond(to: item, InboxResponse(id: item.request.id, decision: .defer_,
                                            reason: "Flick quit"))
        }
        pending.removeAll()
        server?.stop()
        isListening = false
    }

    // MARK: - Socket handling (off the main actor)

    private nonisolated func handleConnection(_ conn: SocketConnection) {
        defer { conn.close() }
        while true {
            let frame: InboxFrame?
            do {
                frame = try conn.readFrame()
            } catch {
                break
            }
            guard let frame else { break }  // EOF: adapter went away.

            switch frame {
            case .request(let request):
                Task { @MainActor [weak self] in
                    self?.receive(request, on: conn)
                }
            case .cancel(let id):
                Task { @MainActor [weak self] in
                    self?.withdraw(id: id)
                }
            case .ping:
                try? conn.send(.pong)
            case .response, .pong:
                continue
            }
        }
        // The adapter hung up. Anything it was blocked on is moot — most often
        // the user answered in the terminal, or the hook timed out.
        Task { @MainActor [weak self] in
            self?.withdrawAll(on: conn)
        }
    }

    // MARK: - Intake

    private func receive(_ request: InboxRequest, on conn: SocketConnection) {
        // Demo cards from `flick test` are not real sessions; listing
        // them would leave a phantom row behind after the card is answered.
        if request.agent.rawValue != "test" {
            store?.upsertSession(from: request)
        }

        switch request.type {
        case .sessionStart:
            refreshSessions()
            try? conn.send(.response(InboxResponse(id: request.id, decision: .ack)))
            return
        case .sessionEnd:
            store?.markSessionEnded(request.sessionID)
            sessionAllowlist.removeValue(forKey: request.sessionID)
            terminalOnly.remove(request.sessionID)
            withdrawAll(sessionID: request.sessionID)
            refreshSessions()
            try? conn.send(.response(InboxResponse(id: request.id, decision: .ack)))
            return
        default:
            break
        }

        // Approvals shifted to the terminal: hand the question straight back
        // so the user answers in their editor, and stay silent here.
        if request.blocking, terminalOnly.contains(request.sessionID) {
            store?.record(request)
            store?.resolve(id: request.id, decision: .defer_, reply: nil)
            try? conn.send(.response(InboxResponse(id: request.id, decision: .defer_,
                                                   reason: reasonText(for: .defer_))))
            refreshSessions()
            return
        }

        // A blanket allow the user granted earlier in this session answers
        // immediately — but only up to the risk level of the card the grant
        // was made on, and never for anything we labelled destructive.
        if request.type == .approval,
           let grantedCeiling = sessionAllowlist[request.sessionID],
           request.risk <= grantedCeiling,
           request.risk < .high {
            store?.record(request)
            store?.resolve(id: request.id, decision: .allow, reply: nil)
            try? conn.send(.response(InboxResponse(id: request.id, decision: .allow,
                                                   reason: "allowed for this session")))
            refreshHistory()
            return
        }

        // Collapse repeat notifications, but never collapse a decision anyone
        // is blocked on.
        if !request.blocking {
            let key = request.dedupeKey
            if let seen = recentNotificationKeys[key], Date().timeIntervalSince(seen) < 20 {
                try? conn.send(.response(InboxResponse(id: request.id, decision: .ack, reason: "duplicate")))
                return
            }
            recentNotificationKeys[key] = Date()
        }

        store?.record(request)

        let item = PendingItem(request: request,
                               connection: request.blocking ? conn : nil,
                               receivedAt: Date())

        if request.type.isActionable {
            // A newer question supersedes an older one from the same session.
            // Withdraw properly — dropping the item alone would leave the old
            // banner in Notification Center and its history row unresolved.
            let superseded = pending.filter {
                $0.request.sessionID == request.sessionID
                    && !$0.request.blocking && $0.request.type == .question
            }
            for old in superseded { withdraw(id: old.id) }
            pending.append(item)
            notifier.notify(request)
        } else {
            // finished / error: notify, keep out of the actionable list.
            notifier.notify(request)
            store?.resolve(id: request.id, decision: .ack, reply: nil)
        }

        if !request.blocking {
            try? conn.send(.response(InboxResponse(id: request.id, decision: .ack)))
        }

        refreshSessions()
        refreshHistory()
    }

    // MARK: - Resolution

    func resolve(id: String, decision: InboxDecision, reply: String?) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let item = pending[index]
        pending.remove(at: index)

        if decision == .allowSession {
            sessionAllowlist[item.request.sessionID] = item.request.risk
        }

        if item.request.blocking {
            respond(to: item, InboxResponse(id: id, decision: decision, reply: reply,
                                            reason: reasonText(for: decision)))
        } else if let text = reply, !text.isEmpty {
            // Nobody is blocked, so the only way in is the session's own
            // messaging socket.
            deliverOutOfBand(text: text, for: item)
        }

        store?.resolve(id: id, decision: decision, reply: reply)
        notifier.withdraw(id: id)
        refreshHistory()

        refreshSessions()
    }

    private func deliverOutOfBand(text: String, for item: PendingItem) {
        let channel = item.request.channel
            ?? store?.session(id: item.request.sessionID)?.channel
        guard let channel else {
            lastError = "No way to reach that session — reply not sent."
            return
        }
        // Off the main actor: send() blocks briefly listening for a rejection,
        // and the popover must not freeze while it does.
        Task.detached(priority: .userInitiated) {
            let result = MessagingClient.send(text: text, over: channel)
            await Broker.shared.noteReplyResult(result)
        }
    }

    private func noteReplyResult(_ result: MessagingClient.SendResult) {
        switch result {
        case .delivered:
            lastError = nil
        case .unavailable(let why):
            lastError = "Reply not delivered: \(why)"
        }
    }

    private func reasonText(for decision: InboxDecision) -> String {
        switch decision {
        case .allow: return "Allowed from Flick"
        case .allowSession: return "Allowed for this session from Flick"
        case .deny: return "Denied from Flick"
        case .reply: return "Answered from Flick"
        case .defer_: return "Deferred to the terminal prompt"
        case .timeout: return "No response in time; falling back to the terminal prompt"
        case .ack, .unavailable: return ""
        }
    }

    private func respond(to item: PendingItem, _ response: InboxResponse) {
        guard let conn = item.connection else { return }
        try? conn.send(.response(response))
    }

    /// Drops a pending card without asking the user, recording how it ended
    /// (`defer` when the agent stopped caring, `timeout` when nobody answered
    /// in time) so history tells the truth about what happened.
    private func withdraw(id: String, as decision: InboxDecision = .defer_) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let item = pending.remove(at: index)
        store?.resolve(id: item.id, decision: decision, reply: nil)
        notifier.withdraw(id: id)
        refreshHistory()
    }

    private func withdrawAll(on conn: SocketConnection) {
        let doomed = pending.filter { $0.connection === conn }
        for item in doomed { withdraw(id: item.id) }
    }

    private func withdrawAll(sessionID: String) {
        let doomed = pending.filter { $0.request.sessionID == sessionID }
        for item in doomed { withdraw(id: item.id) }
    }

    // MARK: - Timers

    private func tick() {
        let now = Date()
        // Expire anything past its deadline. The agent falls back to its own
        // prompt, which is the safe outcome.
        for item in pending {
            if let expires = item.expiresAt, expires <= now {
                if item.request.blocking {
                    respond(to: item, InboxResponse(id: item.id, decision: .timeout,
                                                    reason: reasonText(for: .timeout)))
                }
                withdraw(id: item.id, as: .timeout)
            }
        }
        // Drop dedupe keys we no longer need.
        recentNotificationKeys = recentNotificationKeys.filter { now.timeIntervalSince($0.value) < 60 }

        // Re-check session liveness every few seconds so closed terminals
        // disappear from the list without waiting for a new event. The check
        // is just a kill(pid, 0) per session, so this is cheap.
        sessionSweepCounter += 1
        if sessionSweepCounter >= 3 {
            sessionSweepCounter = 0
            refreshSessions()
        }

        // Countdown labels repaint themselves via TimelineView; invalidating
        // the whole broker every second re-rendered every card and made the
        // popover feel sluggish.
    }

    /// Rebuilds the session list, dropping any whose process has gone away.
    ///
    /// A session that crashed or whose terminal was closed never sends a
    /// "session ended" event, so without this check dead sessions linger in the
    /// list for hours and make the app look like it is lying.
    func refreshSessions() {
        let candidates = store?.activeSessions() ?? []
        var live: [SessionRecord] = []
        for session in candidates {
            if let pid = session.origin.pid {
                if ProcessTree.isAlive(pid: pid) {
                    live.append(session)
                } else {
                    endDeadSession(session.id)
                }
            } else if Date().timeIntervalSince(session.lastSeen) < 1800 {
                // No pid to check: fall back to "seen recently".
                live.append(session)
            } else {
                endDeadSession(session.id)
            }
        }

        // Collapse rows that share a live process: resuming or clearing a
        // conversation starts a new session id inside the same agent process,
        // and the superseded id would otherwise linger as a phantom row.
        var newestByPID: [Int32: String] = [:]
        var deduped: [SessionRecord] = []
        for session in live.sorted(by: { $0.lastSeen > $1.lastSeen }) {
            if let pid = session.origin.pid {
                if newestByPID[pid] != nil {
                    endDeadSession(session.id)
                    continue
                }
                newestByPID[pid] = session.id
            }
            deduped.append(session)
        }
        sessions = deduped
    }

    /// A session found dead by the liveness sweep gets the same teardown as an
    /// explicit "session ended" event: its cards are withdrawn (non-blocking
    /// questions have no expiry and would otherwise linger forever) and its
    /// allow grant is revoked.
    private func endDeadSession(_ sessionID: String) {
        store?.markSessionEnded(sessionID)
        sessionAllowlist.removeValue(forKey: sessionID)
        terminalOnly.remove(sessionID)
        withdrawAll(sessionID: sessionID)
    }

    func refreshHistory() {
        history = store?.recentHistory(limit: 60) ?? []
    }

    /// Shift a session's approvals to the terminal (or bring them back).
    /// Enabling also hands any cards already waiting straight back, so the
    /// switch takes effect on the question currently on screen too.
    func setTerminalOnly(_ sessionID: String, _ enabled: Bool) {
        if enabled {
            terminalOnly.insert(sessionID)
            let waiting = pending.filter { $0.request.sessionID == sessionID && $0.request.blocking }
            for item in waiting {
                respond(to: item, InboxResponse(id: item.id, decision: .defer_,
                                                reason: reasonText(for: .defer_)))
                withdraw(id: item.id)
            }
        } else {
            terminalOnly.remove(sessionID)
        }
    }

    func clearSessionAllowlist() {
        sessionAllowlist.removeAll()
    }

    var sessionAllowCount: Int { sessionAllowlist.count }
}
