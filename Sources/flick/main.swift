import Foundation
import InboxCore

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    let text = """
    flick — adapter CLI for Flick

    USAGE
      flick hook <event>      Run as a Claude Code hook (reads JSON on stdin).
                                   Events: pretooluse, notification, stop,
                                           sessionstart, sessionend
      flick install           Wire the hooks into ~/.claude/settings.json
      flick uninstall         Remove them again
      flick status            Show whether the app is listening and hooks are installed
      flick test [--risky]    Send a fake approval request to the menu bar
      flick reply --socket <path> [--token <t>] <text>
                                   Push text into a running session's inbox

    ENVIRONMENT
      FLICK_SOCKET           Override the broker socket path
      FLICK_WAIT_SECONDS     How long a hook waits for you (default 570)
    """
    print(text)
    exit(2)
}

guard let command = arguments.first else { usage() }

switch command {
case "hook":
    guard arguments.count >= 2 else { usage() }
    exit(ClaudeHook.run(event: arguments[1]))

case "install":
    do {
        let backup = try Installer.install()
        print("Installed Flick hooks into \(Installer.settingsURL.path)")
        print("Backup: \(backup)")
        print("Hook binary: \(Installer.executablePath)")
        print("")
        print("Start (or restart) Claude Code sessions to pick up the change.")
    } catch {
        FileHandle.standardError.write(Data("install failed: \(error)\n".utf8))
        exit(1)
    }

case "uninstall":
    do {
        let backup = try Installer.uninstall()
        print("Removed Flick hooks.")
        print("Backup: \(backup)")
    } catch {
        FileHandle.standardError.write(Data("uninstall failed: \(error)\n".utf8))
        exit(1)
    }

case "status":
    let socket = InboxPaths.socketPath
    let alive = SocketServer.isServerAlive(at: socket)
    print("socket:   \(socket)")
    print("app:      \(alive ? "listening" : "not running")")
    print("hooks:    \(Installer.isInstalled() ? "installed" : "not installed")")
    print("database: \(InboxPaths.databasePath)")
    exit(alive ? 0 : 1)

case "test":
    let risky = arguments.contains("--risky")
    let cwd = FileManager.default.currentDirectoryPath
    let message = risky ? "rm -rf ./build   # example only" : "echo \"hello from Flick\""
    let assessment = RiskClassifier.assess(toolName: "Bash", command: message)
    let request = InboxRequest(
        agent: AgentKind("test"),
        sessionID: "test-session",
        project: "test card — not real",
        cwd: cwd,
        type: .approval,
        title: "Bash",
        message: message,
        detail: "This is a demo card sent by `flick test`.\nNo command runs no matter what you press.",
        actions: [.allow, .deny, .reply, .allowSession],
        risk: assessment.level,
        blocking: true,
        timeoutMS: 120_000,
        origin: SessionOrigin.current(),
        channel: ResponseChannel.fromEnvironment())

    print("Sent. Waiting up to 120s for your decision in the menu bar…")
    let response = InboxClient().submit(request)
    print("decision: \(response.decision.rawValue)")
    if let reply = response.reply { print("reply:    \(reply)") }
    if let reason = response.reason { print("reason:   \(reason)") }

case "reply":
    // Mostly a debugging aid for the messaging channel, and a building block
    // for adapters that have no blocking hook to answer through.
    var socketPath: String?
    var token: String?
    var words: [String] = []
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--socket":
            index += 1
            socketPath = index < arguments.count ? arguments[index] : nil
        case "--token":
            index += 1
            token = index < arguments.count ? arguments[index] : nil
        default:
            words.append(arguments[index])
        }
        index += 1
    }
    guard let socketPath, !words.isEmpty else { usage() }
    let channel = ResponseChannel(kind: "messaging", socketPath: socketPath, token: token)
    switch MessagingClient.send(text: words.joined(separator: " "), over: channel) {
    case .delivered:
        print("delivered")
    case .unavailable(let why):
        FileHandle.standardError.write(Data("not delivered: \(why)\n".utf8))
        exit(1)
    }

default:
    usage()
}
