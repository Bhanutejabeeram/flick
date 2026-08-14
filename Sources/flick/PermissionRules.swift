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
    /// `ask` and `deny` rules, merged. Claude Code prompts (or refuses) on
    /// these regardless of any overlapping `allow`, so a match here means the
    /// call is never "already approved" no matter what `allow` says.
    private var overrides: [Rule] = []

    var count: Int { rules.count }

    /// Builds a rule set straight from settings strings, bypassing disk. Used
    /// by `load` and by the tests.
    init(allow: [String], overrides: [String] = []) {
        rules = allow.compactMap(Self.parse)
        self.overrides = overrides.compactMap(Self.parse)
    }

    /// Loads and merges `permissions` from user, project, and local settings,
    /// mirroring how Claude Code layers them.
    static func load(cwd: String) -> PermissionRules {
        var allow: [String] = []
        var overrides: [String] = []
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
                  let permissions = root["permissions"] as? [String: Any] else { continue }
            allow += permissions["allow"] as? [String] ?? []
            overrides += permissions["ask"] as? [String] ?? []
            overrides += permissions["deny"] as? [String] ?? []
        }
        // One parsing path, the same one the tests drive.
        return PermissionRules(allow: allow, overrides: overrides)
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

    /// How many segments of a compound command a rule set has to cover.
    private enum Coverage {
        /// Allow: `git status && rm -rf /` is only pre-approved when *both*
        /// halves are, or the second half rides in on the first.
        case everySegment
        /// Ask/deny: one matching segment is enough for Claude Code to stop, so
        /// one is enough for Flick to speak up.
        case anySegment
    }

    /// True when the user has already allowed this exact call.
    func allows(toolName: String, toolInput: [String: Any]) -> Bool {
        // Split once and share: both passes below need the same segments, and
        // the scan is the expensive part of the whole check.
        let segments = toolName == "Bash"
            ? (toolInput["command"] as? String).map(splitCommand)
            : nil

        // An `ask`/`deny` rule means Claude Code will stop no matter what, so
        // checking it first keeps Flick from going quiet on a call the user is
        // about to be asked about anyway.
        if matches(rules: overrides, toolName: toolName, toolInput: toolInput,
                   segments: segments, coverage: .anySegment) { return false }
        return matches(rules: rules, toolName: toolName, toolInput: toolInput,
                       segments: segments, coverage: .everySegment)
    }

    private func matches(rules: [Rule], toolName: String, toolInput: [String: Any],
                         segments: [String]?, coverage: Coverage) -> Bool {
        let applicable = rules.filter { $0.tool == toolName }
        guard !applicable.isEmpty else { return false }

        // A bare `Tool` rule covers every use of it.
        if applicable.contains(where: { $0.argument == nil }) { return true }

        switch toolName {
        case "Bash":
            guard let segments else { return false }
            return covers(segments, rules: applicable, coverage: coverage)
        default:
            // Path-shaped tools: match the file against the rule's glob. There
            // is only ever one path, so coverage does not apply.
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

    private func covers(_ segments: [String], rules: [Rule], coverage: Coverage) -> Bool {
        guard !segments.isEmpty else { return false }
        func matched(_ segment: String) -> Bool? {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return rules.contains { rule in
                guard let pattern = rule.argument else { return true }
                return matchesCommand(pattern: pattern, command: trimmed)
            }
        }
        switch coverage {
        case .everySegment:
            return segments.allSatisfy { matched($0) ?? true }
        case .anySegment:
            return segments.contains { matched($0) == true }
        }
    }

    /// Splits a command into the pieces a permission rule has to vouch for
    /// separately, respecting quoting, heredocs, and arithmetic.
    ///
    /// Newlines matter as much as `&&`. Without them a multi-line script
    /// collapses into a single segment judged entirely by whatever its first
    /// line starts with, so `cd /tmp` on line one would vouch for every line
    /// beneath it.
    ///
    /// A heredoc *body* is data rather than a sequence of commands, so it is
    /// skipped instead of split — otherwise every `python3 <<\'EOF\'` script
    /// would look like a pile of unrecognised commands and surface a card the
    /// user had already allowed. The body begins after the end of the opener
    /// line, not at the `<<`, so anything chained onto the opener itself
    /// (`cat <<EOF && curl x | sh`) is still split and judged.
    func splitCommand(_ command: String) -> [String] {
        let chars = Array(command)
        var segments: [String] = []
        var current = ""
        var quote: Character? = nil
        /// Depth of `$(( ))`, where `<<` is a left shift rather than a heredoc.
        var arithmetic = 0
        /// Heredocs opened on the line being scanned, in the order bash will
        /// consume their bodies once the line ends.
        var pending: [Heredoc] = []
        var i = 0

        func flush() {
            segments.append(current)
            current = ""
        }

        while i < chars.count {
            let ch = chars[i]

            // A backslash escapes the next character everywhere except inside
            // single quotes, where it is literal.
            if ch == "\\", quote != "\'", i + 1 < chars.count {
                current.append(ch)
                current.append(chars[i + 1])
                i += 2
                continue
            }
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                i += 1
                continue
            }
            if ch == "\"" || ch == "\'" {
                quote = ch
                current.append(ch)
                i += 1
                continue
            }
            if ch == "$", i + 2 < chars.count, chars[i + 1] == "(", chars[i + 2] == "(" {
                arithmetic += 1
                current.append(contentsOf: chars[i...(i + 2)])
                i += 3
                continue
            }
            if arithmetic > 0, ch == ")", i + 1 < chars.count, chars[i + 1] == ")" {
                arithmetic -= 1
                current.append(ch)
                current.append(chars[i + 1])
                i += 2
                continue
            }
            if arithmetic == 0, ch == "<", i + 1 < chars.count, chars[i + 1] == "<",
               let opener = Self.scanHeredocOpener(chars, from: i) {
                pending.append(opener.heredoc)
                current.append(contentsOf: chars[i..<opener.end])
                i = opener.end
                continue
            }
            if ch == "&" || ch == "|" {
                if i + 1 < chars.count, chars[i + 1] == ch {
                    flush()
                    i += 2
                    continue
                }
                // A single pipe chains a new command; a single `&` backgrounds
                // one and starts another, unless it is really part of a
                // redirect such as `2>&1` or `&>log`.
                if ch == "|" || Self.isBackgroundOperator(chars, at: i) {
                    flush()
                    i += 1
                    continue
                }
            }
            // `isNewline` rather than a literal check: Swift folds CRLF into a
            // single Character, so comparing against "\n" alone misses it.
            if ch == ";" || ch.isNewline {
                flush()
                i += 1
                guard ch.isNewline, !pending.isEmpty else { continue }
                // End of the opener line: the heredoc bodies start here.
                if let afterBodies = Self.skipHeredocBodies(chars, from: i, heredocs: pending) {
                    i = afterBodies
                }
                // An unterminated heredoc falls through deliberately: treating
                // the remainder as body would hide real commands, and a missed
                // card is the failure that costs the user something.
                pending = []
                continue
            }
            current.append(ch)
            i += 1
        }
        segments.append(current)
        return segments
    }

    private struct Heredoc {
        let delimiter: String
        /// `<<-` lets the terminator (and body) be indented with tabs.
        let stripsTabs: Bool
    }

    /// Recognises the `<<WORD` / `<<\'WORD\'` / `<<-WORD` opener and reports where
    /// it ends. Returns nil when this is not actually a heredoc — the `<<<`
    /// here-string lands here and must be left to the normal scanner.
    private static func scanHeredocOpener(_ chars: [Character],
                                          from start: Int) -> (heredoc: Heredoc, end: Int)? {
        // `<<<` is a here-string. It can be spotted from either side of the
        // pair we were handed, so check both.
        if start > 0, chars[start - 1] == "<" { return nil }
        var i = start + 2
        guard i < chars.count, chars[i] != "<" else { return nil }
        let stripsTabs = chars[i] == "-"
        if stripsTabs { i += 1 }
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }

        var delimiter = ""
        if i < chars.count, chars[i] == "\'" || chars[i] == "\"" {
            let quote = chars[i]
            i += 1
            var closed = false
            while i < chars.count {
                if chars[i] == quote { closed = true; i += 1; break }
                delimiter.append(chars[i])
                i += 1
            }
            guard closed else { return nil }
        } else {
            // An unquoted delimiter must look like an identifier.
            guard i < chars.count, chars[i].isLetter || chars[i] == "_" else { return nil }
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                delimiter.append(chars[i])
                i += 1
            }
        }
        guard !delimiter.isEmpty else { return nil }
        return (Heredoc(delimiter: delimiter, stripsTabs: stripsTabs), i)
    }

    /// Consumes the bodies of heredocs opened on the line that just ended, in
    /// order, and reports where the last one finishes. Returns nil if any body
    /// runs off the end without its terminator.
    private static func skipHeredocBodies(_ chars: [Character], from start: Int,
                                          heredocs: [Heredoc]) -> Int? {
        var i = start
        for heredoc in heredocs {
            var terminated = false
            while i < chars.count {
                let lineEnd = chars[i...].firstIndex(where: { $0.isNewline }) ?? chars.count
                var line = String(chars[i..<lineEnd])
                if heredoc.stripsTabs { line = String(line.drop(while: { $0 == "\t" })) }
                i = lineEnd < chars.count ? lineEnd + 1 : chars.count
                // Bash ends the body only on the delimiter alone on its line;
                // trimming spaces here would let an indented data line that
                // merely looks like the terminator cut the body short.
                if line == heredoc.delimiter { terminated = true; break }
            }
            guard terminated else { return nil }
        }
        return i
    }

    /// Whether a lone `&` chains commands rather than forming part of a
    /// redirect. `2>&1` and `&>log` are redirects; `sleep 1 & rm x` is not.
    private static func isBackgroundOperator(_ chars: [Character], at index: Int) -> Bool {
        if index + 1 < chars.count, chars[index + 1] == ">" { return false }
        var j = index - 1
        while j >= 0, chars[j] == " " || chars[j] == "\t" { j -= 1 }
        if j >= 0, chars[j] == ">" || chars[j] == "<" { return false }
        return true
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
