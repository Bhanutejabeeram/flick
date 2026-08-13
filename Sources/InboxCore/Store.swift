import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A live agent session the app knows about.
public struct SessionRecord: Identifiable, Hashable, Sendable {
    public var id: String
    public var agent: AgentKind
    public var project: String
    public var cwd: String
    public var origin: SessionOrigin
    public var channel: ResponseChannel?
    public var firstSeen: Date
    public var lastSeen: Date
    public var isActive: Bool

    public init(id: String, agent: AgentKind, project: String, cwd: String,
                origin: SessionOrigin, channel: ResponseChannel?,
                firstSeen: Date, lastSeen: Date, isActive: Bool) {
        self.id = id
        self.agent = agent
        self.project = project
        self.cwd = cwd
        self.origin = origin
        self.channel = channel
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.isActive = isActive
    }
}

/// A request as it appears in history, with how it was resolved.
public struct HistoryRecord: Identifiable, Hashable, Sendable {
    public var id: String
    public var agent: AgentKind
    public var sessionID: String
    public var project: String
    public var type: RequestType
    public var title: String
    public var message: String
    public var risk: RiskLevel
    public var createdAt: Date
    public var resolvedAt: Date?
    public var decision: InboxDecision?
    public var reply: String?
}

/// Small SQLite database for session metadata and recent request history.
/// Serialized behind one queue; safe to call from any thread.
public final class InboxStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "inbox.store")

    public init(path: String = InboxPaths.databasePath) throws {
        InboxPaths.ensureSupportDirectory()
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw StoreError.open(String(cString: sqlite3_errmsg(handle)))
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA busy_timeout=3000;")
        try migrate()
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    public enum StoreError: Error, CustomStringConvertible {
        case open(String)
        case sql(String)
        public var description: String {
            switch self {
            case .open(let m): return "sqlite open failed: \(m)"
            case .sql(let m): return "sqlite error: \(m)"
            }
        }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sql(message)
        }
    }

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS sessions (
            session_id     TEXT PRIMARY KEY,
            agent          TEXT NOT NULL,
            project        TEXT NOT NULL,
            cwd            TEXT NOT NULL,
            tty            TEXT,
            pid            INTEGER,
            term_program   TEXT,
            bundle_id      TEXT,
            channel_kind   TEXT,
            channel_socket TEXT,
            channel_token  TEXT,
            first_seen     REAL NOT NULL,
            last_seen      REAL NOT NULL,
            is_active      INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS requests (
            id          TEXT PRIMARY KEY,
            session_id  TEXT NOT NULL,
            agent       TEXT NOT NULL,
            project     TEXT NOT NULL,
            cwd         TEXT NOT NULL,
            type        TEXT NOT NULL,
            title       TEXT NOT NULL,
            message     TEXT NOT NULL,
            detail      TEXT,
            risk        TEXT NOT NULL,
            created_at  REAL NOT NULL,
            resolved_at REAL,
            decision    TEXT,
            reply       TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_requests_created ON requests(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_requests_session ON requests(session_id);
        """)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    // MARK: - Sessions

    public func upsertSession(from request: InboxRequest) {
        queue.sync {
            let sql = """
            INSERT INTO sessions (session_id, agent, project, cwd, tty, pid, term_program, bundle_id,
                                  channel_kind, channel_socket, channel_token, first_seen, last_seen, is_active)
            VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?12,1)
            ON CONFLICT(session_id) DO UPDATE SET
                agent=excluded.agent,
                project=excluded.project,
                cwd=excluded.cwd,
                tty=COALESCE(excluded.tty, sessions.tty),
                pid=COALESCE(excluded.pid, sessions.pid),
                term_program=COALESCE(excluded.term_program, sessions.term_program),
                bundle_id=COALESCE(excluded.bundle_id, sessions.bundle_id),
                channel_kind=COALESCE(excluded.channel_kind, sessions.channel_kind),
                channel_socket=COALESCE(excluded.channel_socket, sessions.channel_socket),
                channel_token=COALESCE(excluded.channel_token, sessions.channel_token),
                last_seen=excluded.last_seen,
                is_active=1;
            """
            guard let stmt = try? prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, request.sessionID)
            bind(stmt, 2, request.agent.rawValue)
            bind(stmt, 3, request.project)
            bind(stmt, 4, request.cwd)
            bind(stmt, 5, request.origin.tty)
            if let pid = request.origin.pid { sqlite3_bind_int(stmt, 6, pid) } else { sqlite3_bind_null(stmt, 6) }
            bind(stmt, 7, request.origin.termProgram)
            bind(stmt, 8, request.origin.bundleIdentifier)
            bind(stmt, 9, request.channel?.kind)
            bind(stmt, 10, request.channel?.socketPath)
            bind(stmt, 11, request.channel?.token)
            sqlite3_bind_double(stmt, 12, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    public func markSessionEnded(_ sessionID: String) {
        queue.sync {
            guard let stmt = try? prepare("UPDATE sessions SET is_active=0, last_seen=?2 WHERE session_id=?1") else { return }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, sessionID)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    public func activeSessions(since: TimeInterval = 6 * 3600) -> [SessionRecord] {
        queue.sync {
            let sql = """
            SELECT session_id, agent, project, cwd, tty, pid, term_program, bundle_id,
                   channel_kind, channel_socket, channel_token, first_seen, last_seen, is_active
            FROM sessions WHERE is_active=1 AND last_seen > ?1 ORDER BY last_seen DESC;
            """
            guard let stmt = try? prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970 - since)
            var out: [SessionRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(sessionRow(stmt))
            }
            return out
        }
    }

    public func session(id: String) -> SessionRecord? {
        queue.sync {
            let sql = """
            SELECT session_id, agent, project, cwd, tty, pid, term_program, bundle_id,
                   channel_kind, channel_socket, channel_token, first_seen, last_seen, is_active
            FROM sessions WHERE session_id=?1;
            """
            guard let stmt = try? prepare(sql) else { return nil }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return sessionRow(stmt)
        }
    }

    private func sessionRow(_ stmt: OpaquePointer?) -> SessionRecord {
        func text(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        let origin = SessionOrigin(
            tty: text(4),
            pid: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_int(stmt, 5),
            termProgram: text(6),
            bundleIdentifier: text(7))
        let channel: ResponseChannel? = text(8).map {
            ResponseChannel(kind: $0, socketPath: text(9), token: text(10))
        }
        return SessionRecord(
            id: text(0) ?? "",
            agent: AgentKind(text(1) ?? "other"),
            project: text(2) ?? "",
            cwd: text(3) ?? "",
            origin: origin,
            channel: channel,
            firstSeen: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11)),
            lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12)),
            isActive: sqlite3_column_int(stmt, 13) == 1)
    }

    // MARK: - Requests

    public func record(_ request: InboxRequest) {
        queue.sync {
            let sql = """
            INSERT OR REPLACE INTO requests
                (id, session_id, agent, project, cwd, type, title, message, detail, risk, created_at)
            VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11);
            """
            guard let stmt = try? prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, request.id)
            bind(stmt, 2, request.sessionID)
            bind(stmt, 3, request.agent.rawValue)
            bind(stmt, 4, request.project)
            bind(stmt, 5, request.cwd)
            bind(stmt, 6, request.type.rawValue)
            bind(stmt, 7, request.title)
            bind(stmt, 8, request.message)
            bind(stmt, 9, request.detail)
            bind(stmt, 10, request.risk.rawValue)
            sqlite3_bind_double(stmt, 11, request.createdAt.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    public func resolve(id: String, decision: InboxDecision, reply: String?) {
        queue.sync {
            guard let stmt = try? prepare(
                "UPDATE requests SET resolved_at=?2, decision=?3, reply=?4 WHERE id=?1") else { return }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            bind(stmt, 3, decision.rawValue)
            bind(stmt, 4, reply)
            sqlite3_step(stmt)
        }
    }

    public func recentHistory(limit: Int = 100) -> [HistoryRecord] {
        queue.sync {
            let sql = """
            SELECT id, agent, session_id, project, type, title, message, risk, created_at, resolved_at, decision, reply
            FROM requests ORDER BY created_at DESC LIMIT ?1;
            """
            guard let stmt = try? prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var out: [HistoryRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                func text(_ i: Int32) -> String? {
                    guard let c = sqlite3_column_text(stmt, i) else { return nil }
                    return String(cString: c)
                }
                out.append(HistoryRecord(
                    id: text(0) ?? "",
                    agent: AgentKind(text(1) ?? "other"),
                    sessionID: text(2) ?? "",
                    project: text(3) ?? "",
                    type: RequestType(rawValue: text(4) ?? "") ?? .approval,
                    title: text(5) ?? "",
                    message: text(6) ?? "",
                    risk: RiskLevel(rawValue: text(7) ?? "low") ?? .low,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
                    resolvedAt: sqlite3_column_type(stmt, 9) == SQLITE_NULL
                        ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9)),
                    decision: text(10).flatMap(InboxDecision.init(rawValue:)),
                    reply: text(11)))
            }
            return out
        }
    }

    /// Keeps the database small; history is a convenience, not an archive.
    public func pruneHistory(olderThan days: Int = 14) {
        queue.sync {
            guard let stmt = try? prepare("DELETE FROM requests WHERE created_at < ?1") else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970 - Double(days) * 86400)
            sqlite3_step(stmt)
        }
    }
}
