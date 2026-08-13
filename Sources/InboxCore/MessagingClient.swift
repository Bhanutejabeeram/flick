import Foundation

/// Pushes free text into a running Claude Code session over its cross-session
/// messaging socket.
///
/// This is the only outbound channel that works when no hook is blocking — it
/// is how "reply" reaches a session that is simply idle. It is best-effort by
/// design: the socket only exists on recent versions, the session can refuse
/// inbound messages, and a message can never stand in for consent on a pending
/// permission prompt.
public enum MessagingClient {
    public enum SendResult: Sendable {
        case delivered
        case unavailable(String)

        public var isDelivered: Bool {
            if case .delivered = self { return true }
            return false
        }
    }

    public static func send(text: String, over channel: ResponseChannel) -> SendResult {
        guard channel.kind == "messaging", let path = channel.socketPath, !path.isEmpty else {
            return .unavailable("session has no messaging channel")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return .unavailable("messaging socket is gone (session likely exited)")
        }

        let conn: SocketConnection
        do {
            conn = try InboxClient(path: path).connect()
        } catch {
            return .unavailable("could not connect to session: \(error)")
        }
        defer { conn.close() }
        conn.setReadTimeout(seconds: 3)

        do {
            if let token = channel.token, !token.isEmpty {
                try conn.write(try line(["type": "auth", "token": token]))
            }
            try conn.write(try line(["type": "message", "content": text]))
        } catch {
            return .unavailable("write failed: \(error)")
        }

        // The messaging protocol has no formal ack, but a session that rejects
        // the auth token or refuses inbound messages answers (or resets) right
        // away. Listen briefly so an immediate rejection is reported instead
        // of being passed off as success; silence still means best-effort sent.
        conn.setReadTimeout(seconds: 1)
        if let reply = try? conn.readLine(), let ack = String(data: reply, encoding: .utf8) {
            let lowered = ack.lowercased()
            if lowered.contains("\"error\"") || lowered.contains("unauthorized") || lowered.contains("denied") {
                return .unavailable("session rejected the message: \(ack.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        return .delivered
    }

    private static func line(_ object: [String: String]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }
}
