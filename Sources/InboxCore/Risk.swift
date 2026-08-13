import Foundation

/// Heuristic risk labelling for the approval card.
///
/// This never decides anything on the user's behalf — it only colours the card
/// so a destructive command is not one muscle-memory click away from approval.
public enum RiskClassifier {
    private struct Rule {
        let pattern: String
        let risk: RiskLevel
        let why: String
        /// Whether the rule also applies to file *content* being written (not
        /// just commands). Deliberately rare: prose mentioning `sudo` is
        /// normal in a README, but planting a pipe-to-shell line or touching
        /// a secrets path is dangerous wherever it appears.
        var scansContent: Bool = false
    }

    private static let rules: [Rule] = [
        Rule(pattern: #"\brm\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*[rf]"#, risk: .high, why: "recursive/forced delete"),
        Rule(pattern: #"\bsudo\b"#, risk: .high, why: "runs as root"),
        Rule(pattern: #"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba|z|fi)?sh\b"#, risk: .high, why: "pipes a download into a shell", scansContent: true),
        Rule(pattern: #"\bgit\s+push\b[^\n]*(--force|-f)\b"#, risk: .high, why: "force push"),
        Rule(pattern: #"\bgit\s+reset\s+--hard\b"#, risk: .high, why: "discards local changes"),
        Rule(pattern: #"\bgit\s+clean\b[^\n]*-[a-zA-Z]*f"#, risk: .high, why: "deletes untracked files"),
        Rule(pattern: #"\b(npm|pnpm|yarn)\s+publish\b"#, risk: .high, why: "publishes a package"),
        Rule(pattern: #"\bdd\s+if="#, risk: .high, why: "raw disk write"),
        Rule(pattern: #"\b(mkfs|diskutil\s+erase|fdisk)\b"#, risk: .high, why: "formats a disk"),
        Rule(pattern: #"\bkillall\b|\bpkill\b"#, risk: .high, why: "kills processes by name"),
        Rule(pattern: #"\bchmod\s+(-R\s+)?777\b"#, risk: .high, why: "world-writable permissions"),
        Rule(pattern: #"\b(drop\s+table|drop\s+database|truncate\s+table)\b"#, risk: .high, why: "destroys database data"),
        Rule(pattern: #"\bterraform\s+(apply|destroy)\b"#, risk: .high, why: "changes infrastructure"),
        Rule(pattern: #"\bkubectl\s+delete\b"#, risk: .high, why: "deletes cluster resources"),
        Rule(pattern: #"\baws\s+\S+\s+(delete|terminate)"#, risk: .high, why: "deletes cloud resources"),
        Rule(pattern: #"\b(shutdown|reboot)\b"#, risk: .high, why: "restarts the machine"),
        Rule(pattern: #"~/\.ssh|id_rsa|id_ed25519|\.env\b|credentials|\.pem\b"#, risk: .high, why: "touches secrets", scansContent: true),

        Rule(pattern: #"\bgit\s+(push|commit|merge|rebase|checkout|switch|tag)\b"#, risk: .medium, why: "changes git state"),
        Rule(pattern: #"\b(npm|pnpm|yarn|bun)\s+(install|add|remove|i)\b"#, risk: .medium, why: "changes dependencies"),
        Rule(pattern: #"\b(pip|pip3|uv|brew|cargo|gem|go)\s+(install|add|remove|uninstall)\b"#, risk: .medium, why: "installs software"),
        Rule(pattern: #"\b(curl|wget|http|nc)\b"#, risk: .medium, why: "network access"),
        Rule(pattern: #"\bdocker\s+(run|compose|build|rm)\b"#, risk: .medium, why: "container operation"),
        Rule(pattern: #"\b(mv|cp)\s+"#, risk: .medium, why: "moves or overwrites files"),
        Rule(pattern: #"\brm\b"#, risk: .medium, why: "deletes a file"),
        Rule(pattern: #">\s*\S"#, risk: .medium, why: "redirects output over a file"),
    ]

    private static let compiled: [(NSRegularExpression, RiskLevel, String, Bool)] = rules.compactMap {
        guard let re = try? NSRegularExpression(pattern: $0.pattern, options: [.caseInsensitive]) else { return nil }
        return (re, $0.risk, $0.why, $0.scansContent)
    }

    /// Tools that only read state are safe to show as low risk regardless of
    /// their arguments.
    private static let readOnlyTools: Set<String> = [
        "Read", "Glob", "Grep", "NotebookRead", "WebFetch", "WebSearch", "TodoWrite", "ListAgents",
    ]

    public struct Assessment: Sendable {
        public var level: RiskLevel
        public var reasons: [String]
    }

    /// `command` must be the FULL command or path being approved — never a
    /// display summary, which is truncated for rendering and would let a long
    /// command hide its dangerous tail past the cutoff. `content` is file
    /// content being written, scanned only by content-scoped rules.
    public static func assess(toolName: String, command: String, content: String? = nil) -> Assessment {
        if readOnlyTools.contains(toolName) {
            return Assessment(level: .low, reasons: [])
        }

        var level: RiskLevel = toolName == "Bash" ? .low : .medium
        var reasons: [String] = []
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        for (re, risk, why, _) in compiled where re.firstMatch(in: command, options: [], range: range) != nil {
            if risk > level { level = risk }
            if risk >= .medium { reasons.append(why) }
        }
        if let content, !content.isEmpty {
            let contentRange = NSRange(content.startIndex..<content.endIndex, in: content)
            for (re, risk, why, scansContent) in compiled
            where scansContent && re.firstMatch(in: content, options: [], range: contentRange) != nil {
                if risk > level { level = risk }
                reasons.append(why)
            }
        }

        switch toolName {
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            if level < .medium { level = .medium }
            if reasons.isEmpty { reasons.append("modifies files") }
        default:
            break
        }
        return Assessment(level: level, reasons: Array(Set(reasons)).sorted())
    }
}

public enum ProjectNaming {
    /// Best-effort project label for a working directory: the git root's name
    /// when there is one, otherwise the directory name.
    public static func projectName(for cwd: String) -> String {
        var dir = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        let fm = FileManager.default
        var depth = 0
        while depth < 12, dir.path != "/" {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return dir.lastPathComponent
            }
            dir.deleteLastPathComponent()
            depth += 1
        }
        let leaf = URL(fileURLWithPath: cwd, isDirectory: true).lastPathComponent
        return leaf.isEmpty ? cwd : leaf
    }
}
