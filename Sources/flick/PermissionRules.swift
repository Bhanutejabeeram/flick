import Foundation

/// A conservative reimplementation of Claude Code's permission-rule matching,
/// used for one purpose only: staying quiet about tool calls the user has
/// already allowed.
///
/// Safety note on the failure direction. This matcher only ever decides to
/// *skip* the inbox. Skipping hands the call back to Claude Code's own
/// permission flow, which re-evaluates the real rules and prompts in the
/// terminal if it disagrees. So a false "this is allowed" costs at most a
/// missed menu-bar notification — it can never cause something to run that the
/// user had not already permitted. Anything this matcher cannot parse is
/// treated as not-allowed, which surfaces the card.
struct PermissionRules {
    private struct Rule {
        let tool: String
        /// nil means "any use of this tool".
        let argument: String?
    }

    private var rules: [Rule] = []

    var count: Int { rules.count }

    /// Loads and merges `permissions.allow` from user, project, and local
    /// settings, mirroring how Claude Code layers them.
    static func load(cwd: String) -> PermissionRules {
        var rules = PermissionRules()
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(".claude/settings.json"),
        ]
        let projectDir = URL(fileURLWithPath: cwd, isDirectory: true)
        candidates.append(projectDir.appendingPathComponent(".claude/settings.json"))
        candidates.append(projectDir.appendingPathComponent(".claude/settings.local.json"))
        candidates.append(home.appendingPathComponent(".claude/settings.local.json"))

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let permissions = root["permissions"] as? [String: Any],
                  let allow = permissions["allow"] as? [String] else { continue }
            for raw in allow {
                if let rule = parse(raw) { rules.rules.append(rule) }
            }
        }
        return rules
    }

    private static func parse(_ raw: String) -> Rule? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else {
            guard !trimmed.isEmpty, !trimmed.contains(")") else { return nil }
            return Rule(tool: trimmed, argument: nil)
        }
        let tool = String(trimmed[trimmed.startIndex..<open])
        let argStart = trimmed.index(after: open)
        let argEnd = trimmed.index(before: trimmed.endIndex)
        guard argStart <= argEnd else { return nil }
        return Rule(tool: tool, argument: String(trimmed[argStart..<argEnd]))
    }

    /// True when the user has already allowed this exact call.
    func allows(toolName: String, toolInput: [String: Any]) -> Bool {
        let applicable = rules.filter { $0.tool == toolName }
        guard !applicable.isEmpty else { return false }

        // A bare `Tool` rule allows every use of it.
        if applicable.contains(where: { $0.argument == nil }) { return true }

        switch toolName {
        case "Bash":
            guard let command = toolInput["command"] as? String else { return false }
            return allowsCommand(command, rules: applicable)
        default:
            // Path-shaped tools: match the file against the rule's glob.
            let path = (toolInput["file_path"] as? String)
                ?? (toolInput["path"] as? String)
                ?? (toolInput["notebook_path"] as? String)
            guard let path else { return false }
            return applicable.contains { rule in
                guard let pattern = rule.argument else { return true }
                return matchesGlob(pattern: pattern, path: path)
            }
        }
    }

    private func allowsCommand(_ command: String, rules: [Rule]) -> Bool {
        // Compound commands are only allowed when every segment is allowed;
        // otherwise `git status && rm -rf /` would sail through on the first
        // half.
        let segments = splitCommand(command)
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy { segment in
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return true }
            return rules.contains { rule in
                guard let pattern = rule.argument else { return true }
                return matchesCommand(pattern: pattern, command: trimmed)
            }
        }
    }

    /// Splits on shell operators, respecting quotes well enough to avoid
    /// splitting inside a quoted string.
    private func splitCommand(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character? = nil
        var index = command.startIndex

        while index < command.endIndex {
            let ch = command[index]
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                index = command.index(after: index)
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
                index = command.index(after: index)
                continue
            }
            let next = command.index(after: index)
            if ch == "&" || ch == "|" {
                if next < command.endIndex, command[next] == ch {
                    segments.append(current)
                    current = ""
                    index = command.index(after: next)
                    continue
                }
                if ch == "|" {  // a single pipe still chains a new command
                    segments.append(current)
                    current = ""
                    index = next
                    continue
                }
            }
            if ch == ";" {
                segments.append(current)
                current = ""
                index = next
                continue
            }
            current.append(ch)
            index = next
        }
        segments.append(current)
        return segments
    }

    /// `Bash(npm run build:*)` is a prefix rule; `Bash(git --version)` is exact.
    private func matchesCommand(pattern: String, command: String) -> Bool {
        if pattern.hasSuffix(":*") {
            let prefix = String(pattern.dropLast(2)).trimmingCharacters(in: .whitespaces)
            guard !prefix.isEmpty else { return false }
            if command == prefix { return true }
            // Require a word boundary so `git ad` does not match `git add`.
            return command.hasPrefix(prefix + " ") || command.hasPrefix(prefix + "\t")
        }
        if pattern == "*" { return true }
        return command == pattern
    }

    private func matchesGlob(pattern: String, path: String) -> Bool {
        // Claude writes absolute path rules with a leading `//`.
        var normalized = pattern
        while normalized.hasPrefix("//") { normalized.removeFirst() }
        return fnmatch(normalized, path, 0) == 0
    }
}
