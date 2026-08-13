import AppKit
import Foundation
import InboxCore

/// "Jump to session": bring the window the agent is actually running in to the
/// front.
///
/// Best effort by nature — we activate the owning app, and where the terminal
/// exposes scripting we also select the exact tab by its tty. If AppleScript is
/// unavailable or not yet permitted, activating the app is still a useful
/// outcome, so failures are silent rather than noisy.
enum SessionFocus {
    static func focus(_ origin: SessionOrigin) {
        guard let bundleID = origin.bundleIdentifier else {
            activateFallback(origin)
            return
        }
        activate(bundleID: bundleID)

        guard let tty = origin.tty, !tty.isEmpty else { return }
        switch bundleID {
        case "com.apple.Terminal":
            run(appleScript: terminalScript(tty: tty))
        case "com.googlecode.iterm2":
            run(appleScript: itermScript(tty: tty))
        default:
            break  // VS Code and friends expose no tab-level scripting.
        }
    }

    private static func activate(bundleID: String) {
        let workspace = NSWorkspace.shared
        if let app = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            app.activate(options: [.activateAllWindows])
        } else if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func activateFallback(_ origin: SessionOrigin) {
        // Without a known terminal, the best we can do is raise whatever owns
        // the process group, if it is still around.
        guard let pid = origin.pid,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(options: [.activateAllWindows])
    }

    private static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            return
                        end if
                    end try
                end repeat
            end repeat
        end tell
        """
    }

    private static func itermScript(tty: String) -> String {
        """
        tell application "iTerm"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                                return
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    private static func run(appleScript source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            try? process.run()
        }
    }

    /// Opens the project directory in Finder — handy when the terminal is gone.
    static func revealProject(cwd: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
    }
}
