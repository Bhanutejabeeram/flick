The problem

You give a terminal coding agent like Claude Code or Codex a long task and move on — maybe you open another VS Code tab, switch to Chrome, or start browsing something else.

Meanwhile, the agent reaches a permission prompt or needs your input and stops completely, waiting for you.

But you’re never notified.

Ten minutes later, you switch back and realize your agent has been sitting there almost the entire time waiting for one approval.

With multiple agents and terminal sessions running, it gets even worse. You don’t know which agent is working, which one needs you, or which one has already finished unless you keep checking manually.

Coding agents should work in the background — you shouldn’t have to babysit your terminal.

What Flick does about it

Flick lives in your macOS menu bar and gives your terminal coding agents a way to reach you.

The moment an agent needs permission or input, Flick notifies you and shows exactly what it’s waiting for.

Approve it, deny it, or reply directly from Flick — without switching back to your terminal or hunting through different windows.

When an agent finishes, Flick lets you know that too.

You keep doing your thing. Flick brings you back only when your agents need you.

## Install

### Homebrew (recommended)

```bash
brew tap Bhanutejabeeram/tap
brew trust Bhanutejabeeram/tap   # newer Homebrew asks once for third-party taps
brew install --cask flick --no-quarantine
flick install                    # wires hooks into ~/.claude/settings.json (backs it up first)
```

The `--no-quarantine` flag skips the "Apple could not verify" warning. The app
is not notarized yet.

### From source

```bash
./scripts/build-app.sh          # builds and installs /Applications/Flick.app and the flick CLI
open /Applications/Flick.app    # menu-bar icon appears, no Dock icon
flick install                   # wires hooks into ~/.claude/settings.json (backs it up first)
```

Restart your Claude Code sessions afterwards so they pick up the hooks.

To check everything is connected:

```bash
flick status
# socket:   ~/Library/Application Support/Flick/inbox.sock
# app:      listening
# hooks:    installed
```

To try a card without waiting for a real prompt:

```bash
flick test            # a benign approval
flick test --risky    # one that trips the destructive-command classifier
```

Removal is symmetric. `flick uninstall` strips only the entries tagged `_flick`
and leaves any hooks you wrote by hand alone.

### One setting worth changing

In System Settings > Notifications > Flick, set the alert style to
**Persistent** (older macOS calls it Alerts). The default style disappears after
about five seconds, which is not much use for something you are meant to answer.
With Persistent, the notification waits for you, and hovering over it reveals
the Allow and Deny buttons.

## What actually works

| Capability | Claude Code | Notes |
|---|---|---|
| Menu-bar badge and native notification | ✅ | Banner carries Allow/Deny buttons |
| Approval card with the exact command | ✅ | Never summarised or truncated away |
| Allow / Deny from the menu bar | ✅ | Real decision returned to the agent |
| Allow for this session | ✅ | Capped at the risk level it was granted on, never destructive commands |
| Reply with text to a blocked tool call | ✅ | Denies the call, hands Claude your words as the reason |
| Reply to an idle session | ⚠️ | Uses the cross-session messaging socket, needs a recent Claude Code with inbound messages enabled |
| Jump to the originating session | ✅ | Exact tab in Terminal and iTerm, app-level for VS Code |
| Multi-session routing | ✅ | Each response goes back to the connection it came from |
| Session and request history | ✅ | SQLite, pruned after 14 days |
| Codex CLI | ❌ | Not built, Codex was not installed to verify against |
| Other terminal agents (PTY bridge) | ❌ | Not built |

There is a real distinction between the two halves of this. Notifying you that
something happened is easy and works almost anywhere. Letting you answer needs a
proper two way channel. For Claude Code that channel is a blocking `PreToolUse`
hook, and it is the only one. A message pushed at a session cannot answer a
permission prompt that is already waiting.

## Design

A small core plus one adapter per agent, so agent-specific vocabulary never
leaks into the broker or the UI.

```
Claude hooks ─┐
Codex (todo) ─┼─→ flick helper ─→ Unix socket ─→ Broker ─→ Menu-bar UI
PTY (todo)   ─┘   (canonical event)                    │  │
                                                       │  └─→ Notifications
                                                       └────→ SQLite
```

Every adapter translates into one canonical event:

```jsonc
{
  "agent": "claude",              // open-ended; unknown agents still render
  "session_id": "…",
  "project": "flick",             // git root name, else directory name
  "cwd": "/Users/you/code/thing",
  "type": "approval",             // approval | question | finished | error
  "title": "Bash",
  "message": "rm -rf ./dist",     // shown verbatim
  "detail": "{ …full tool input… }",
  "actions": ["allow", "deny", "reply"],
  "risk": "high",
  "blocking": true,               // someone is holding a connection for the answer
  "timeout_ms": 570000,
  "origin": { "tty": "/dev/ttys004", "bundleIdentifier": "com.microsoft.VSCode" },
  "channel": { "kind": "messaging", "socket_path": "…", "token": "…" }
}
```

One JSON object per line, both directions, over
`~/Library/Application Support/Flick/inbox.sock` (mode `0600`).

### Everything stays local

No network, no telemetry, no cloud. The socket is user-only. The app never
silently auto-approves anything, and the agent's own sandbox and permission
model are left exactly as they were.

## Three decisions that make it usable

**1. It fails open, always.** If the app is not running, the socket is stale, or
the payload will not parse, the hook prints no decision and exits 0, which
restores Claude Code's normal permission prompt. Flick can annoy you. It cannot
wedge a coding session.

This is also why the timeout is safe. A `PreToolUse` hook that times out does
not block the tool call. Claude falls through to its own prompt. So a card you
never answer costs you nothing beyond the wait.

Worth knowing if you build something similar: returning
`permissionDecision: "ask"` does **not** restore the standard prompt. Omitting
the decision entirely is what does, and that is what the helper emits for defer,
timeout, and every failure path.

**2. It stays quiet about things you already allowed.** A naive hook would
surface a card for every `npm install`. This machine has well over a hundred
`permissions.allow` rules, and Claude would never have prompted for most of
them. So the helper re-evaluates those rules itself (prefix rules, exact rules,
path globs) and skips anything already permitted, along with
`bypassPermissions`, `plan`, and `acceptEdits` for edit tools. Read-only tools
are never intercepted at all.

The matcher is deliberately conservative, and its failure direction is safe. It
can only decide to *skip*, and skipping hands the call back to Claude's real
permission check. A wrong "this is allowed" costs a missed notification, never
an unauthorised execution.

Getting that matcher to agree with the shell took more care than expected. A
compound command only counts as allowed when *every* segment is, or
`git status && rm -rf /` would ride in on its first half. Newlines separate
commands just like `&&` does. A lone `&` separates too, though `2>&1` and
`&>log` are redirects and must not. Heredoc bodies are data rather than
commands, so they are skipped instead of judged, but anything chained onto the
opening line still gets checked. And `$((a<<b))` is arithmetic, not a heredoc.
Each of those was a real way for a command to slip past unnoticed, and each has
a test.

**3. Destructive commands get treated differently.** A classifier labels
`rm -rf`, `sudo`, `curl … | sh`, force pushes, `drop table`, secrets paths and
similar as destructive. Those cards lose the "Allow for session" button, lose
the one-click Allow on the notification banner, and a session-wide allow never
covers them. Approving something dangerous should never be one piece of muscle
memory.

## Sound and notifications

Every event you might be waiting on makes a sound, including a session simply
finishing, which is the one people walk away for. Each event sounds different so
you can tell what happened without looking. A decision needed uses your system
alert sound, a finished run is softer, and destructive commands and errors are
deliberately harder to ignore.

Flick plays these itself rather than attaching them to the notification. A
notification sound is swallowed by any Do Not Disturb, including the one macOS
turns on by itself while your display sleeps, which is exactly when you have
stepped away and most need to hear it.

## Verified

Tested against the live hook contract, not just at unit level:

- Fail-open with the app stopped, giving `{"hookSpecificOutput":{"hookEventName":"PreToolUse"}}` and exit 0
- Blocking approval with the app running and no answer, held exactly 6s, then fell back to the terminal prompt
- Non-blocking notification acked in 67 ms, so the agent is never slowed down
- Allowlisted `npm install left-pad` produced no card, the matcher stayed silent
- Non-allowlisted `curl … | sh` surfaced, classified `high`, "Allow for session" withheld
- Decision round trip, where a stub broker answering `allow` produced `permissionDecision: "allow"`
- tty and terminal detection, giving `/dev/ttys004` and `com.microsoft.VSCode` via a process-tree walk
- Messaging channel emitting `{"type":"auth"}` then `{"type":"message"}`, verified on the wire
- Notification banner carrying working Allow and Deny buttons
- Popover staying on screen in a full-screen space, where the auto-hiding menu bar used to drag its top off the display

Not yet verified: delivery of a reply into a *live* remote Claude session. The
wire format is confirmed against a stub, but acceptance depends on that
session's inbound-message setting.

## Layout

```
Sources/InboxCore/        Protocol, socket transport, SQLite store, risk classifier,
                          process-tree tty detection, messaging client
Sources/FlickApp/         MenuBarExtra app: broker, inbox UI, approval cards,
                          notifications, jump-to-session
Sources/flick/            CLI: hook adapter, permission-rule matcher, installer
Tests/FlickTests/         Permission matching, panel placement, event classification
scripts/build-app.sh      Bundles and ad-hoc signs the .app, links the CLI
```

Run the tests with `swift test`.

Why an `.app` bundle rather than a bare SwiftPM executable: `MenuBarExtra` and
`UserNotifications` both need a real bundle identifier. Without one the app
falls back to AppleScript banners, which have no buttons.

## Roadmap

Phases 1 to 3 of the build plan are done. What remains, in order:

- **Phase 4, Codex adapter.** Use Codex's own notification and approval surfaces
  where the installed version exposes them, and a PTY bridge where it does not.
  Deliberately not written yet, because Codex is not installed here, and an
  adapter written against a guessed interface is exactly the "claiming universal
  support before each adapter is proven" trap.
- **Phase 6, polish.** Keyboard shortcuts, project icons, a history view (the
  data is already stored), launch-at-login.
- **Phase 7, expand.** Gemini CLI, OpenCode, Cursor and VS Code extension.

The seams are ready for these. `AgentKind` is open-ended, so an unknown agent
that speaks the canonical event renders and routes correctly without touching
the broker or the UI.

## Known gaps

- Focusing an exact tab uses AppleScript, so the first jump asks for Automation
  permission. Denying it still leaves app-level focus working.
- VS Code's integrated terminal has no tab-level scripting, so jumping there
  activates the window rather than the specific terminal.
- The `Stop` hook fires on every turn. It is installed, and the inbox treats it
  as a low-key "finished" event rather than a demand for attention.
- MCP tools are not intercepted by default. Add a `/^mcp__/` matcher to the
  `PreToolUse` block by hand if you want them.
- The app is ad-hoc signed, so notifications cannot be marked time-sensitive.
  That would need a paid Apple Developer account, and without it a Focus mode
  will hold banners back. The sound still plays.
