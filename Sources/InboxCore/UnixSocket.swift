import Foundation

public enum SocketError: Error, CustomStringConvertible {
    case create(String)
    case bind(String)
    case listen(String)
    case connect(String)
    case pathTooLong(String)
    case closed
    case timedOut

    public var description: String {
        switch self {
        case .create(let s): return "socket() failed: \(s)"
        case .bind(let s): return "bind() failed: \(s)"
        case .listen(let s): return "listen() failed: \(s)"
        case .connect(let s): return "connect() failed: \(s)"
        case .pathTooLong(let p): return "socket path too long (>103 bytes): \(p)"
        case .closed: return "connection closed"
        case .timedOut: return "timed out"
        }
    }
}

private func errnoString() -> String { String(cString: strerror(errno)) }

/// Fills a `sockaddr_un` with `path` and invokes `body` with a pointer to it.
private func withSockAddr<R>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> R) throws -> R {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < capacity else { throw SocketError.pathTooLong(path) }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    return try withUnsafePointer(to: &addr) { ptr in
        try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, len) }
    }
}

/// A connected socket. Reads are line-buffered; writes are serialized so any
/// thread can answer a request.
public final class SocketConnection: @unchecked Sendable {
    public let fd: Int32
    private var readBuffer = Data()
    private let writeLock = NSLock()
    private var closed = false

    public init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Blocks until one newline-terminated frame arrives. Returns nil at EOF.
    public func readLine() throws -> Data? {
        while true {
            if let idx = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.subdata(in: readBuffer.startIndex..<idx)
                readBuffer.removeSubrange(readBuffer.startIndex...idx)
                if line.isEmpty { continue }
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let n = read(fd, &chunk, chunk.count)
            if n == 0 { return nil }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.timedOut }
                throw SocketError.closed
            }
            readBuffer.append(contentsOf: chunk[0..<n])
        }
    }

    public func readFrame() throws -> InboxFrame? {
        guard let line = try readLine() else { return nil }
        return try InboxCoding.decoder.decode(InboxFrame.self, from: line)
    }

    public func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        if closed { throw SocketError.closed }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = Foundation.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 {
                    if errno == EINTR { continue }
                    throw SocketError.closed
                }
                offset += n
            }
        }
    }

    public func send(_ frame: InboxFrame) throws {
        try write(try InboxCoding.encodeLine(frame))
    }

    /// Applies a receive timeout so a blocked adapter cannot hang forever.
    public func setReadTimeout(seconds: Double) {
        guard seconds > 0 else { return }
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }
        closed = true
        shutdown(fd, SHUT_RDWR)
        _ = Foundation.close(fd)
    }

    public var isClosed: Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        return closed
    }
}

/// Listens on a Unix domain socket and hands each connection to a callback on
/// its own thread. The callback owns the connection's lifetime.
public final class SocketServer: @unchecked Sendable {
    private let path: String
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "inbox.socket.accept")
    private var running = false
    private let handler: (SocketConnection) -> Void

    public init(path: String, handler: @escaping (SocketConnection) -> Void) {
        self.path = path
        self.handler = handler
    }

    /// Returns true if some other process already owns the socket.
    public static func isServerAlive(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let ok = (try? withSockAddr(path: path) { addr, len in
            connect(fd, addr, len) == 0
        }) ?? false
        return ok
    }

    public func start() throws {
        InboxPaths.ensureSupportDirectory()
        // A stale socket file from a crash would block bind(); only remove it
        // once we know nobody is listening.
        if FileManager.default.fileExists(atPath: path) {
            if SocketServer.isServerAlive(at: path) {
                throw SocketError.bind("another Flick is already listening at \(path)")
            }
            try? FileManager.default.removeItem(atPath: path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.create(errnoString()) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        // Restrict the umask across bind() so the socket node is never
        // world-accessible, even for the instant before the chmod below.
        let previousUmask = umask(0o177)
        let bound = try withSockAddr(path: path) { addr, len in bind(fd, addr, len) }
        umask(previousUmask)
        guard bound == 0 else {
            close(fd)
            throw SocketError.bind(errnoString())
        }
        // Only this user may talk to the broker.
        chmod(path, 0o600)

        guard listen(fd, 64) == 0 else {
            close(fd)
            throw SocketError.listen(errnoString())
        }

        listenFD = fd
        running = true
        queue.async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while running {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if !running { break }
                usleep(50_000)
                continue
            }
            let conn = SocketConnection(fd: client)
            let thread = Thread { [handler] in handler(conn) }
            thread.name = "inbox.conn.\(client)"
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    public func stop() {
        running = false
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
        }
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Client side used by hook helpers and the PTY bridge.
public final class InboxClient {
    private let path: String

    public init(path: String = InboxPaths.socketPath) {
        self.path = path
    }

    public func connect() throws -> SocketConnection {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.create(errnoString()) }
        let rc = try withSockAddr(path: path) { addr, len in Foundation.connect(fd, addr, len) }
        guard rc == 0 else {
            let err = errnoString()
            close(fd)
            throw SocketError.connect(err)
        }
        return SocketConnection(fd: fd)
    }

    /// Sends a request and waits for the user's decision.
    ///
    /// Non-blocking requests return as soon as the broker acknowledges receipt.
    /// If the app is not running we fail open with `.unavailable` so the agent
    /// keeps working with its normal prompt rather than hanging.
    public func submit(_ request: InboxRequest) -> InboxResponse {
        let conn: SocketConnection
        do {
            conn = try connect()
        } catch {
            return InboxResponse(id: request.id, decision: .unavailable,
                                 reason: "Flick is not running (\(error))")
        }
        defer { conn.close() }

        // Leave headroom so we answer before the agent's own hook timeout.
        let waitSeconds = request.blocking ? Double(request.timeoutMS) / 1000.0 : 10.0
        conn.setReadTimeout(seconds: max(waitSeconds, 1))

        do {
            try conn.send(.request(request))
            while true {
                guard let frame = try conn.readFrame() else {
                    return InboxResponse(id: request.id, decision: .unavailable, reason: "broker closed connection")
                }
                switch frame {
                case .response(let r) where r.id == request.id:
                    return r
                case .ping:
                    try? conn.send(.pong)
                default:
                    continue
                }
            }
        } catch SocketError.timedOut {
            return InboxResponse(id: request.id, decision: .timeout, reason: "no response within \(Int(waitSeconds))s")
        } catch {
            return InboxResponse(id: request.id, decision: .unavailable, reason: "\(error)")
        }
    }
}
