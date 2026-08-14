import Foundation
import InboxCore

/// Translates Claude Code's hook protocol into canonical inbox events.
///
/// Everything here fails open. If the app is not running, if the socket is
/// stale, if we cannot parse the payload — we print nothing and exit 0, which
/// leaves Claude Code's own permission flow exactly as it was. Flick
/// should never be able to wedge a coding session.
enum ClaudeHook {
    // MARK: - Entry point

    static func run(event: String) -> Int32 {
        let raw = readStdin()
        let input = (try? JSONSerialization.jsonObject(with: raw) as? [String: Any]) ?? [:]

        switch event.lowercased() {
        case "pretooluse":
            return handlePreToolUse(input)
        case "notification":
            return handleNotification(input)
        case "stop":
            return handleStop(input)
        case "sessionstart":
            return handleSessionLifecycle(input, type: .sessionStart)
        case "sessionend":
            return handleSessionLifecycle(input, type: .sessionEnd)
        default:
            FileHandle.standardError.write(Data("flick: unknown hook event \(event)\n".utf8))
            return 0
        }
    }

    // MARK: - PreToolUse

    private static func handlePreToolUse(_ input: [String: Any]) -> Int32 {
        let toolName = input["tool_name"] as? String ?? "tool"
        let toolInput = input["tool_input"] as? [String: Any] ?? [:]
        let cwd = input["cwd"] as? String ?? FileManager.default.currentDirectoryPath
        let mode = input["permission_mode"] as? String ?? "default"

        // Modes where Claude Code would not have stopped to ask. Interrupting
        // those would make the product a nuisance rather than a safety net.
        let silentModes: Set<String> = ["bypassPermissions", "plan", "auto", "dontAsk"]
        if silentModes.contains(mode) { return passThrough() }
        if mode == "acceptEdits", editTools.contains(toolName) { return passThrough() }

        // Already allowed by the user's own rules: stay quiet. A call that asks
        // to run outside the sandbox is the exception — Claude Code prompts for
        // those whatever the allow list says, so trusting the rules here would
        // leave the user staring at a terminal prompt Flick never mentioned.
        if !escapesSandbox(toolInput),
           PermissionRules.load(cwd: cwd).allows(toolName: toolName, toolInput: toolInput) {
            return passThrough()
        }

        let summary = summarize(toolName: toolName, toolInput: toolInput)
        // Classify on the full structured input, never the display summary:
        // the summary is truncated for rendering, and a command longer than
        // the cutoff would have its dangerous tail hidden from the rules.
        let risk = RiskClassifier.assess(toolName: toolName,
                                         command: classifierCommand(toolName: toolName, toolInput: toolInput),
                                         content: classifierContent(toolName: toolName, toolInput: toolInput))

        var actions: [InboxAction] = [.allow, .deny, .reply]
        if risk.level < .high { actions.append(.allowSession) }

        let request = InboxRequest(
            agent: .claude,
            sessionID: input["session_id"] as? String ?? "unknown",
            project: ProjectNaming.projectName(for: cwd),
            cwd: cwd,
            type: .approval,
            title: toolName,
            message: summary.message,
            detail: summary.detail,
            actions: actions,
            risk: risk.level,
            blocking: true,
            timeoutMS: waitMilliseconds,
            origin: SessionOrigin.current(),
            channel: ResponseChannel.fromEnvironment())

        let response = InboxClient().submit(request)

        switch response.decision {
        case .allow, .allowSession:
            return emit(decision: "allow",
                        reason: response.reason ?? "Approved in Flick")
        case .deny:
            return emit(decision: "deny",
                        reason: response.reason ?? "Denied in Flick")
        case .reply:
            // A typed reply on an approval card means "no, do this instead" —
            // deny the call and hand Claude the user's words as the reason, so
            // the guidance is not lost.
            let text = response.reply?.trimmingCharacters(in: .whitespacesAndNewlines)
            return emit(decision: "deny",
                        reason: (text?.isEmpty == false ? text! : "Denied in Flick"))
        case .defer_, .timeout, .ack, .unavailable:
            // Hand back to Claude Code's normal prompt. Note that emitting
            // `ask` would NOT do this — omitting the decision entirely is what
            // restores the standard flow.
            return passThrough()
        }
    }

    private static let editTools: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]

    /// Whether the call explicitly opts out of the sandbox, which makes Claude
    /// Code prompt however the allow list reads.
    ///
    /// Only the one key, and only when true. Guessing at other spellings looks
    /// harmless but is not: `sandbox: false` is the *ordinary* state of a Bash
    /// call, so treating it as an escape would disable allow-list silencing
    /// wholesale and raise a blocking card for every command the user had
    /// already approved.
    private static func escapesSandbox(_ toolInput: [String: Any]) -> Bool {
        toolInput["dangerouslyDisableSandbox"] as? Bool == true
    }

    /// The full command-or-path text the risk rules scan for a tool call.
    private static func classifierCommand(toolName: String, toolInput: [String: Any]) -> String {
        switch toolName {
        case "Bash":
            return toolInput["command"] as? String ?? ""
        case "Write", "Edit", "MultiEdit":
            return toolInput["file_path"] as? String ?? ""
        case "NotebookEdit":
            return toolInput["notebook_path"] as? String ?? ""
        default:
            return compactJSON(toolInput)
        }
    }

    /// File content being planted on disk, for the content-scoped rules
    /// (pipe-to-shell lines, secrets paths). Nil for non-writing tools.
    private static func classifierContent(toolName: String, toolInput: [String: Any]) -> String? {
        switch toolName {
        case "Write":
            return toolInput["content"] as? String
        case "Edit":
            return toolInput["new_string"] as? String
        case "MultiEdit":
            let edits = toolInput["edits"] as? [[String: Any]] ?? []
            let joined = edits.compactMap { $0["new_string"] as? String }.joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        case "NotebookEdit":
            return toolInput["new_source"] as? String
        default:
            return nil
        }
    }

    /// How long we hold the hook open. Kept under the configured hook timeout
    /// so we answer first; if we do lose the race, a hook timeout is not a
    /// block — Claude Code just falls through to its own prompt.
    private static var waitMilliseconds: Int {
        if let raw = ProcessInfo.processInfo.environment["FLICK_WAIT_SECONDS"],
           let seconds = Int(raw), seconds > 0 {
            return seconds * 1000
        }
        return 570_000
    }

    // MARK: - Notification

    private static func handleNotification(_ input: [String: Any]) -> Int32 {
        // Older payloads carry a `notification_type`; current Claude Code
        // sends only a human-readable `message`. Use the type when present,
        // otherwise classify from the text — and never degrade a real
        // notification into a generic "unknown" error card.
        let kind = input["notification_type"] as? String
        let text = (input["message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cwd = input["cwd"] as? String ?? FileManager.default.currentDirectoryPath
        let sessionID = input["session_id"] as? String ?? "unknown"

        if kind == "auth_success" { return 0 }  // Not worth a card.

        let type: RequestType = .question
        let title: String
        let message: String
        var actions: [InboxAction] = []
        let lowered = text.lowercased()

        if kind == "permission_prompt" || lowered.contains("permission") {
            // Claude is blocked on its own prompt — either for a tool we do
            // not intercept, or because our card timed out. We cannot answer
            // this one, so the useful action is taking the user to the window.
            title = "Waiting for permission"
            message = text.isEmpty ? "Claude Code is asking for permission in the terminal." : text
        } else if kind == "idle_prompt" || kind == "agent_needs_input"
                    || lowered.contains("waiting for your input") || lowered.contains("idle") {
            title = "Waiting for you"
            message = text.isEmpty ? "Claude Code finished and is waiting for your next instruction." : text
            actions = [.reply]
        } else if kind == "elicitation_dialog" || kind == "elicitation_url_dialog" {
            title = "Needs input"
            message = "An MCP server is asking for input in the terminal."
        } else {
            title = "Needs attention"
            message = text.isEmpty ? "Claude Code needs attention." : text
        }

        let request = InboxRequest(
            agent: .claude,
            sessionID: sessionID,
            project: ProjectNaming.projectName(for: cwd),
            cwd: cwd,
            type: type,
            title: title,
            message: message,
            actions: actions,
            risk: .low,
            blocking: false,
            origin: SessionOrigin.current(),
            channel: ResponseChannel.fromEnvironment())

        _ = InboxClient().submit(request)
        return 0
    }

    // MARK: - Stop

    private static func handleStop(_ input: [String: Any]) -> Int32 {
        // Never interfere with stopping; this is purely a "your turn" signal.
        if input["stop_hook_active"] as? Bool == true { return 0 }

        let cwd = input["cwd"] as? String ?? FileManager.default.currentDirectoryPath
        let last = (input["last_assistant_message"] as? String) ?? ""
        let summary = last.isEmpty ? "Claude Code finished its turn."
                                   : condense(stripMarkdown(last), limit: 220)

        let request = InboxRequest(
            agent: .claude,
            sessionID: input["session_id"] as? String ?? "unknown",
            project: ProjectNaming.projectName(for: cwd),
            cwd: cwd,
            type: .finished,
            title: "Finished",
            message: summary,
            actions: [.reply],
            risk: .low,
            blocking: false,
            origin: SessionOrigin.current(),
            channel: ResponseChannel.fromEnvironment())

        _ = InboxClient().submit(request)
        return 0
    }

    // MARK: - Session lifecycle

    private static func handleSessionLifecycle(_ input: [String: Any], type: RequestType) -> Int32 {
        let cwd = input["cwd"] as? String ?? FileManager.default.currentDirectoryPath
        let request = InboxRequest(
            agent: .claude,
            sessionID: input["session_id"] as? String ?? "unknown",
            project: ProjectNaming.projectName(for: cwd),
            cwd: cwd,
            type: type,
            title: type == .sessionStart ? "Session started" : "Session ended",
            message: cwd,
            blocking: false,
            origin: SessionOrigin.current(),
            channel: ResponseChannel.fromEnvironment())
        _ = InboxClient().submit(request)
        return 0
    }

    // MARK: - Summarising tool calls

    struct Summary {
        var message: String
        var detail: String?
    }

    static func summarize(toolName: String, toolInput: [String: Any]) -> Summary {
        let pretty = prettyJSON(toolInput)

        switch toolName {
        case "Bash":
            let command = toolInput["command"] as? String ?? ""
            let description = toolInput["description"] as? String
            var detail = pretty
            if let description, !description.isEmpty {
                detail = "\(description)\n\n\(pretty)"
            }
            return Summary(message: condense(command, limit: 1200), detail: detail)

        case "Write":
            let path = toolInput["file_path"] as? String ?? ""
            let content = toolInput["content"] as? String ?? ""
            let lines = content.isEmpty ? 0 : content.components(separatedBy: "\n").count
            return Summary(message: "Write \(displayPath(path))  (\(lines) lines)",
                           detail: condense(content, limit: 4000))

        case "Edit", "MultiEdit":
            let path = toolInput["file_path"] as? String ?? ""
            return Summary(message: "Edit \(displayPath(path))", detail: pretty)

        case "NotebookEdit":
            let path = toolInput["notebook_path"] as? String ?? ""
            return Summary(message: "Edit notebook \(displayPath(path))", detail: pretty)

        case "WebFetch":
            let url = toolInput["url"] as? String ?? ""
            return Summary(message: "Fetch \(url)", detail: pretty)

        default:
            if toolName.hasPrefix("mcp__") {
                // Format is mcp__<server>__<tool>; split on the double
                // underscore so servers/tools with underscores in their own
                // names keep their identity on the card.
                let parts = String(toolName.dropFirst("mcp__".count)).components(separatedBy: "__")
                let server = parts.first ?? ""
                let tool = parts.dropFirst().joined(separator: "__").replacingOccurrences(of: "_", with: " ")
                let label = tool.isEmpty ? server : "\(server) · \(tool)"
                return Summary(message: condense(label + " " + compactJSON(toolInput), limit: 600),
                               detail: pretty)
            }
            return Summary(message: condense(compactJSON(toolInput), limit: 600), detail: pretty)
        }
    }

    private static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Notifications render plain text, so markdown markers read as noise
    /// ("**bold**" shows its asterisks). Strip the common inline markers and
    /// collapse links to their label; this is display-only, never shown for
    /// commands the user approves.
    private static func stripMarkdown(_ text: String) -> String {
        var out = text
        for pattern in [
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),   // [label](url) → label
            // Only the ** form: stripping __bold__ would eat the double
            // underscores in real identifiers like __init__.py.
            (#"\*\*(.*?)\*\*"#, "$1"),           // **bold**
            (#"`([^`]*)`"#, "$1"),               // `code`
            (#"(?m)^#{1,6}\s+"#, ""),            // heading markers
            (#"(?m)^\s*[-*+]\s+"#, "• "),        // list bullets
        ] {
            out = out.replacingOccurrences(of: pattern.0, with: pattern.1,
                                           options: .regularExpression)
        }
        return out
    }

    private static func condense(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "\n… (\(trimmed.count - limit) more characters)"
    }

    private static func prettyJSON(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return condense(text, limit: 6000)
    }

    private static func compactJSON(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    // MARK: - Hook I/O

    private static func readStdin() -> Data {
        var data = Data()
        while let chunk = try? FileHandle.standardInput.read(upToCount: 64 * 1024), !chunk.isEmpty {
            data.append(chunk)
            if data.count > 8 * 1024 * 1024 { break }
        }
        return data
    }

    /// Emits no decision, which restores Claude Code's normal permission flow.
    private static func passThrough() -> Int32 {
        let payload: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PreToolUse"]]
        write(payload)
        return 0
    }

    private static func emit(decision: String, reason: String) -> Int32 {
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": decision,
                "permissionDecisionReason": reason,
            ]
        ]
        write(payload)
        return 0
    }

    private static func write(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
