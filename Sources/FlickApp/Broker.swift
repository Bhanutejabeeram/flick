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

/// One line of the agent dashboard: a session, what it is doing, and how long
/// it has been doing it.
struct AgentStatusRow: Identifiable, Equatable {
    var session: SessionRecord
    var status: SessionStatus
    /// The file the agent last had its hands on, relative to the project root.
    var target: String?
    /// The session has gone away and is only still on screen so the user sees
    /// it finish rather than watching a row vanish mid-glance.
    var isEnded: Bool

    var id: String { session.id }
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
    /// @Published so the settings panel's revoke button repaints on change.
    @Published private(set) var sessionAllowlist: [String: RiskLevel] = [:]

    /// What each session is doing, keyed by session id, with the moment it
    /// started doing it. Kept in memory rather than in SQLite on purpose: a
    /// status is only true while the app is watching, and a "Working · 3h"
    /// restored from disk after a restart would be a guess dressed as a fact.
    @Published private(set) var statuses: [String: SessionStatus] = [:]

    /// The file each session last touched. Sticky on purpose: between two edits
    /// an agent runs tools that name no file, and blanking the line every time
    /// would make it flicker rather than inform.
    @Published private(set) var targets: [String: String] = [:]

    /// Sessions that have gone away, held briefly so the user sees them land on
    /// "Finished" instead of watching the row disappear from under the cursor.
    private var ended: [String: (session: SessionRecord, at: Date)] = [:]

    /// How long an ended session stays on the dashboard before it is dropped.
    private let finishedGrace: TimeInterval = 30

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

    // MARK: - Dashboard

    /// Every session worth showing: whatever has stopped for the user first,
    /// then whatever is running, then anything on its way out.
    ///
    /// Within a status the order is by most recent activity, so a row only ever
    /// moves when its status genuinely changed — not merely because another
    /// session did something.
    var agentRows: [AgentStatusRow] {
        let live = sessions.map {
            AgentStatusRow(session: $0, status: status(of: $0),
                           target: targets[$0.id], isEnded: false)
        }
        .sorted {
            let (a, b) = ($0.status.activity.sortPriority, $1.status.activity.sortPriority)
            return a == b ? $0.session.lastSeen > $1.session.lastSeen : a < b
        }

        let liveIDs = Set(sessions.map(\.id))
        let lingering = ended.values
            .filter { !liveIDs.contains($0.session.id) }
            .sorted { $0.at > $1.at }
            .map {
                AgentStatusRow(session: $0.session,
                               status: statuses[$0.session.id] ?? SessionStatus(.finished, since: $0.at),
                               target: targets[$0.session.id], isEnded: true)
            }
        return live + lingering
    }

    /// The recorded status, or a sensible stand-in for a session restored from
    /// the database before any event of ours has been seen for it.
    private func status(of session: SessionRecord) -> SessionStatus {
        statuses[session.id] ?? SessionStatus(.working, since: session.lastSeen)
    }

    /// Applies a transition, leaving the clock alone when nothing actually
    /// changed. Restarting `since` on every repeat event would peg every
    /// duration near zero and make the whole column useless.
    private func noteStatus(_ request: InboxRequest, awaitingUser: Bool) {
        guard request.agent.rawValue != "test" else { return }
        if let target = request.target, !target.isEmpty {
            targets[request.sessionID] = target
        }
        guard let next = SessionStatus.transition(for: request, awaitingUser: awaitingUser) else { return }
        apply(next, to: request.sessionID)
    }

    private func apply(_ next: SessionStatus, to sessionID: String) {
        if let current = statuses[sessionID], current.supersedes(next) { return }
        statuses[sessionID] = next
    }

    /// Back to work once nothing from this session is waiting on the user.
    ///
    /// Only ever lifts a session out of ``SessionActivity/waiting``: a session
    /// that finished or died also sheds its cards, and letting that path
    /// rewrite the status would report a dead session as working.
    private func resumeIfIdle(_ sessionID: String) {
        guard statuses[sessionID]?.activity == .waiting else { return }
        guard !pending.contains(where: { $0.request.sessionID == sessionID }) else { return }
        statuses[sessionID] = SessionStatus(.working)
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
        notifier.onAuthStatus = { [weak self] granted, detail in
            if !granted {
                let hint = detail.map { " (\($0))" } ?? ""
                self?.lastError = "Banners are off — enable Flick in System Settings → Notifications\(hint). The menu-bar badge and sound still work."
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
            store?.upsertSession(from: request,
                                 updateProject: request.type == .sessionStart)
        }

        switch request.type {
        case .sessionStart:
            noteStatus(request, awaitingUser: false)
            refreshSessions()
            try? conn.send(.response(InboxResponse(id: request.id, decision: .ack)))
            return
        case .sessionEnd:
            // Same teardown the liveness sweep performs, including the grace
            // period that keeps the row on screen for a moment.
            endSession(request.sessionID)
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
            // Flick is out of the loop for this session, and gets no event when
            // the user answers in the terminal. A "Waiting" that could only be
            // cleared by the *next* event would sit there stale, so these
            // sessions are reported as working and the "in editor" tag on the
            // row is what says where their prompts went.
            noteStatus(request, awaitingUser: false)
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
            // Answered without the user ever seeing it, so the agent never
            // stopped working.
            noteStatus(request, awaitingUser: false)
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

        noteStatus(request, awaitingUser: request.type.isActionable)

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

        // The agent has its answer and is moving again.
        resumeIfIdle(item.request.sessionID)
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
    ///
    /// Answering the hook is not optional: a blocking request whose card
    /// disappears without a reply leaves the agent stuck for its whole
    /// timeout with no prompt anywhere. Flick may annoy the user; it must
    /// never wedge a session. Writing to an already-closed connection just
    /// fails harmlessly, so this is safe on every withdrawal path.
    private func withdraw(id: String, as decision: InboxDecision = .defer_) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let item = pending.remove(at: index)
        if item.request.blocking {
            respond(to: item, InboxResponse(id: item.id, decision: decision,
                                            reason: reasonText(for: decision)))
        }
        store?.resolve(id: item.id, decision: decision, reply: nil)
        notifier.withdraw(id: id)
        refreshHistory()
        resumeIfIdle(item.request.sessionID)
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
                withdraw(id: item.id, as: .timeout)
            }
        }
        // Drop dedupe keys we no longer need.
        recentNotificationKeys = recentNotificationKeys.filter { now.timeIntervalSince($0.value) < 60 }

        // Retire finished sessions once the user has had a moment to see them,
        // and drop the statuses of sessions nothing refers to any more.
        let expired = Array(ended.filter { now.timeIntervalSince($0.value.at) >= finishedGrace }.keys)
        if !expired.isEmpty {
            // `ended` is not @Published, so the change is announced by hand —
            // before the mutation, which is the order SwiftUI expects.
            objectWillChange.send()
            for id in expired { ended.removeValue(forKey: id) }
            let known = Set(sessions.map(\.id)).union(ended.keys)
            statuses = statuses.filter { known.contains($0.key) }
            targets = targets.filter { known.contains($0.key) }
        }

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
                // Name-checked: a recycled pid must not keep a dead session
                // looking alive forever.
                if ProcessTree.isAlive(pid: pid, recordedName: session.origin.processName) {
                    live.append(session)
                } else {
                    endSession(session.id)
                }
            } else if Date().timeIntervalSince(session.lastSeen) < 1800 {
                // No pid to check: fall back to "seen recently".
                live.append(session)
            } else {
                endSession(session.id)
            }
        }

        // Collapse rows that share a live process: resuming or clearing a
        // conversation starts a new session id inside the same agent process,
        // and the superseded id would otherwise linger as a phantom row.
        //
        // Two guards keep this from ever killing a real session:
        // - only pids owned by a *named agent process* are collapsed. The
        //   no-agent fallback records a shell/login ancestor, which several
        //   distinct sessions in one terminal can legitimately share.
        // - a row with cards still waiting is never collapsed; someone may be
        //   blocked on an answer.
        var newestByPID: [Int32: String] = [:]
        var deduped: [SessionRecord] = []
        for session in live.sorted(by: { $0.lastSeen > $1.lastSeen }) {
            if let pid = session.origin.pid {
                let collapsible = ProcessTree.isAgentProcessName(session.origin.processName)
                    && !pending.contains { $0.request.sessionID == session.id }
                if newestByPID[pid] != nil, collapsible {
                    endSession(session.id, linger: false)
                    continue
                }
                if newestByPID[pid] == nil { newestByPID[pid] = session.id }
            }
            deduped.append(session)
        }
        sessions = deduped
    }

    /// Tears a session down, whether it said goodbye or the liveness sweep
    /// caught it: its cards are withdrawn (non-blocking questions have no
    /// expiry and would otherwise linger forever), its allow grant is revoked,
    /// and a copy is kept for ``finishedGrace`` so the dashboard can show it
    /// finishing instead of blinking out.
    /// `linger` is false for a session being collapsed into a newer one on the
    /// same process. That row is a phantom left behind by a resume or a
    /// `/clear`, not a session that ended, and parking it on the dashboard as
    /// "Finished" would put back the duplicate the collapse exists to remove.
    private func endSession(_ sessionID: String, linger: Bool = true) {
        // Snapshot the row before the store marks it inactive — once it is out
        // of `sessions` there is nothing left to render during the grace period.
        if linger,
           let record = sessions.first(where: { $0.id == sessionID }) ?? store?.session(id: sessionID) {
            objectWillChange.send()   // `ended` is not @Published.
            ended[sessionID] = (record, Date())
        }
        // Settle the status *before* withdrawing cards. Withdrawal lifts a
        // waiting session back to working, and a session that just died must
        // never be reported as running.
        apply(SessionStatus(.finished), to: sessionID)
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
            for item in waiting { withdraw(id: item.id) }
        } else {
            terminalOnly.remove(sessionID)
        }
    }

    func clearSessionAllowlist() {
        sessionAllowlist.removeAll()
    }

    var sessionAllowCount: Int { sessionAllowlist.count }
}
