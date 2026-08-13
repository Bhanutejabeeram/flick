import Foundation
import InboxCore

/// Installs and removes the Claude Code hook wiring in `~/.claude/settings.json`.
///
/// Every hook entry we add is tagged with `_flick`, so uninstall can
/// remove exactly what we added and nothing a human wrote by hand.
enum Installer {
    static let marker = "_flick"

    struct HookSpec {
        let event: String
        let matcher: String?
        let subcommand: String
        let timeout: Int
    }

    /// Which tools we intercept. Read-only tools are deliberately absent: they
    /// never prompt, so intercepting them would only add latency and noise.
    /// MCP tools are left out of the default install for the same reason — add
    /// a `/^mcp__/` matcher by hand if you want them.
    static let specs: [HookSpec] = [
        HookSpec(event: "PreToolUse",
                 matcher: "Bash|Write|Edit|MultiEdit|NotebookEdit",
                 subcommand: "pretooluse",
                 timeout: 600),
        // No matcher: Notification payloads identify themselves by `message`
        // text (and only sometimes a type field), so filtering happens in the
        // handler. A type-string matcher here can silently match nothing.
        HookSpec(event: "Notification",
                 matcher: nil,
                 subcommand: "notification",
                 timeout: 15),
        HookSpec(event: "Stop",
                 matcher: nil,
                 subcommand: "stop",
                 timeout: 15),
        HookSpec(event: "SessionStart",
                 matcher: "startup|resume|clear",
                 subcommand: "sessionstart",
                 timeout: 10),
        HookSpec(event: "SessionEnd",
                 matcher: nil,
                 subcommand: "sessionend",
                 timeout: 5),
    ]

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// Absolute path of this binary, so the hook keeps working regardless of PATH.
    static var executablePath: String {
        let path = CommandLine.arguments.first ?? "flick"
        if path.hasPrefix("/") { return path }
        let resolved = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path).standardizedFileURL.path
        return FileManager.default.fileExists(atPath: resolved) ? resolved : path
    }

    // MARK: - Install

    static func install() throws -> String {
        var root = try readSettings()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let binary = executablePath

        for spec in specs {
            var entries = hooks[spec.event] as? [[String: Any]] ?? []
            // Replace any entry we previously installed for this event.
            entries.removeAll { ($0[marker] as? Bool) == true }

            var entry: [String: Any] = [
                marker: true,
                "hooks": [[
                    "type": "command",
                    "command": "\(shellQuote(binary)) hook \(spec.subcommand)",
                    "timeout": spec.timeout,
                ]],
            ]
            if let matcher = spec.matcher { entry["matcher"] = matcher }
            entries.append(entry)
            hooks[spec.event] = entries
        }

        root["hooks"] = hooks
        let backup = try writeSettings(root)
        return backup
    }

    // MARK: - Uninstall

    static func uninstall() throws -> String {
        var root = try readSettings()
        guard var hooks = root["hooks"] as? [String: Any] else {
            return "Nothing to remove — no hooks configured."
        }
        for spec in specs {
            guard var entries = hooks[spec.event] as? [[String: Any]] else { continue }
            entries.removeAll { ($0[marker] as? Bool) == true }
            if entries.isEmpty {
                hooks.removeValue(forKey: spec.event)
            } else {
                hooks[spec.event] = entries
            }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return try writeSettings(root)
    }

    static func isInstalled() -> Bool {
        guard let root = try? readSettings(),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains { ($0[marker] as? Bool) == true }
        }
    }

    // MARK: - File handling

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard !data.isEmpty else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.malformedSettings
        }
        return root
    }

    /// Writes settings back, leaving a timestamped backup first. Returns the
    /// backup path so the user is told where their old file went.
    private static func writeSettings(_ root: [String: Any]) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        var backupPath = "(no previous settings.json)"
        if fm.fileExists(atPath: settingsURL.path) {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backup = settingsURL.deletingLastPathComponent()
                .appendingPathComponent("settings.json.flick-backup-\(stamp)")
            try fm.copyItem(at: settingsURL, to: backup)
            backupPath = backup.path
        }

        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // Write to a temporary file and swap, so an interrupted write cannot
        // leave the user without settings.
        let temp = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.flick-tmp")
        try data.write(to: temp, options: .atomic)
        _ = try fm.replaceItemAt(settingsURL, withItemAt: temp)
        return backupPath
    }

    private static func shellQuote(_ path: String) -> String {
        guard path.contains(" ") || path.contains("'") else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    enum InstallError: Error, CustomStringConvertible {
        case malformedSettings
        var description: String {
            switch self {
            case .malformedSettings:
                return "~/.claude/settings.json is not a JSON object; refusing to touch it."
            }
        }
    }
}
