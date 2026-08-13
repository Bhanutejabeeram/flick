import Darwin
import Foundation

/// Reads process ancestry so an adapter can work out which terminal it is
/// really running in.
///
/// A hook helper is spawned with pipes for stdio, so `ttyname()` on its own
/// descriptors always fails. The controlling terminal has to come from an
/// ancestor process instead — usually the agent itself, or the shell above it.
public enum ProcessTree {
    public struct Info {
        public var pid: Int32
        public var parentPID: Int32
        public var name: String
        /// Controlling terminal device, or nil when the process has none.
        public var tty: String?
    }

    /// Reads one process's kinfo_proc via sysctl. No subprocess, no PATH
    /// dependency, safe to call on every hook invocation.
    public static func info(for pid: Int32) -> Info? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var size = MemoryLayout<kinfo_proc>.stride
        var proc = kinfo_proc()
        let result = withUnsafeMutablePointer(to: &proc) { pointer -> Int32 in
            pointer.withMemoryRebound(to: UInt8.self, capacity: size) { raw in
                sysctl(&mib, u_int(mib.count), raw, &size, nil, 0)
            }
        }
        guard result == 0, size > 0 else { return nil }

        let name = withUnsafePointer(to: proc.kp_proc.p_comm) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
                String(cString: $0)
            }
        }

        var tty: String? = nil
        let device = proc.kp_eproc.e_tdev
        // NODEV (-1 as dev_t) means the process has no controlling terminal.
        if device != -1, let name = devname(device, S_IFCHR) {
            tty = "/dev/" + String(cString: name)
        }

        return Info(pid: proc.kp_proc.p_pid,
                    parentPID: proc.kp_eproc.e_ppid,
                    name: name,
                    tty: tty)
    }

    /// Whether a process is still around.
    ///
    /// A session that crashed, was killed, or whose terminal was closed never
    /// gets to send a "session ended" event, so liveness has to be checked
    /// rather than trusted.
    public static func isAlive(pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid, 0) == 0 { return true }
        // EPERM means it exists but belongs to someone else.
        return errno == EPERM
    }

    /// Walks from `pid` up towards launchd, nearest ancestor first.
    public static func ancestors(from pid: Int32 = getpid(), limit: Int = 12) -> [Info] {
        var out: [Info] = []
        var current = pid
        while out.count < limit, current > 1 {
            guard let info = info(for: current) else { break }
            out.append(info)
            current = info.parentPID
        }
        return out
    }

    /// The controlling terminal of the nearest ancestor that has one.
    public static func controllingTTY(from pid: Int32 = getpid()) -> String? {
        for info in ancestors(from: pid) {
            if let tty = info.tty { return tty }
        }
        return nil
    }

    /// Process names coding agents run under (p_comm, capped at 16 chars).
    private static let agentProcessNames: Set<String> = [
        "claude", "codex", "gemini", "aider", "node", "bun", "deno",
    ]

    /// Shells an agent may use to spawn a hook (`/bin/sh -c …`). These exit
    /// the moment the hook does, so they are useless as a liveness handle.
    private static let shellNames: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]

    /// The long-lived ancestor that owns this hook invocation — the agent when
    /// one can be identified by name, otherwise the nearest ancestor holding
    /// the controlling terminal after skipping transient shell wrappers.
    ///
    /// Never the calling process itself: a hook helper inherits the controlling
    /// terminal even with piped stdio, so "first process with a tty" matches
    /// the helper — which exits milliseconds later and makes the app believe
    /// the session died. Returns nil when nothing plausible is found; no pid
    /// is safer than a pid that dies with the hook.
    public static func owningProcess(from pid: Int32 = getpid()) -> Info? {
        let chain = Array(ancestors(from: pid).dropFirst())  // never self
        if let agent = chain.first(where: { agentProcessNames.contains($0.name) }) {
            return agent
        }
        var candidates = chain[...]
        while let head = candidates.first, shellNames.contains(head.name), candidates.count > 1 {
            candidates = candidates.dropFirst()
        }
        return candidates.first(where: { $0.tty != nil })
            ?? chain.first(where: { $0.tty != nil })
    }

    /// Names of terminal emulators as they appear in the process table, mapped
    /// to their bundle identifiers.
    private static let terminalProcesses: [(needle: String, bundleID: String)] = [
        ("iTerm2", "com.googlecode.iterm2"),
        ("Terminal", "com.apple.Terminal"),
        ("ghostty", "com.mitchellh.ghostty"),
        ("WezTerm", "com.github.wez.wezterm"),
        ("kitty", "net.kovidgoyal.kitty"),
        ("alacritty", "org.alacritty"),
        ("Warp", "dev.warp.Warp-Stable"),
        ("Hyper", "co.zeit.hyper"),
        ("Code Helper", "com.microsoft.VSCode"),
        ("Code", "com.microsoft.VSCode"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Windsurf", "com.exafunction.windsurf"),
    ]

    /// Identifies the owning terminal app by scanning ancestor process names.
    /// Used only when `TERM_PROGRAM` is missing from the environment.
    public static func terminalBundleID(from pid: Int32 = getpid()) -> String? {
        for info in ancestors(from: pid, limit: 16) {
            for entry in terminalProcesses where info.name.contains(entry.needle) {
                return entry.bundleID
            }
        }
        return nil
    }
}
