import Foundation

/// Everything Flick writes lives under one directory so it is easy to
/// inspect, back up, or delete.
public enum InboxPaths {
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["FLICK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Flick", isDirectory: true)
    }

    /// The listening socket. Unix socket paths are capped at 104 bytes on
    /// Darwin, so this stays short by construction.
    public static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["FLICK_SOCKET"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return supportDirectory.appendingPathComponent("inbox.sock").path
    }

    public static var databasePath: String {
        supportDirectory.appendingPathComponent("inbox.sqlite3").path
    }

    public static var logPath: String {
        supportDirectory.appendingPathComponent("flick.log").path
    }

    @discardableResult
    public static func ensureSupportDirectory() -> Bool {
        let dir = supportDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            return false
        }
    }
}
