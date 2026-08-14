# Flick

A macOS menu-bar app that tells you when your coding agent is waiting on you.

## The problem

You give a terminal coding agent like Claude Code a long task and move on. You
open another VS Code tab, switch to Chrome, start reading something else.

Meanwhile the agent hits a permission prompt and stops. Completely. Waiting for
you.

Nothing tells you. Ten minutes later you switch back and find it has been
sitting there the entire time, needing one approval.

With several agents running it gets worse. You can't tell which one is working,
which one needs you, and which one finished, without checking each terminal by
hand.

Coding agents are supposed to work in the background. You shouldn't have to
babysit a terminal.

## What Flick does

Flick lives in your menu bar and gives your agents a way to reach you.

The moment one needs permission or input, Flick tells you and shows exactly what
it's asking for. Approve it, deny it, or reply — right from the menu bar,
without hunting for the right terminal window. When an agent finishes, you hear
about that too.

Open the popover and you get the whole picture at once: every session, what it's
doing, and how long it's been doing it.

You get on with your day. Flick pulls you back only when an agent actually needs
you.

## Install

### Homebrew

```bash
brew tap Bhanutejabeeram/tap
brew trust Bhanutejabeeram/tap   # newer Homebrew asks once for third-party taps
brew install --cask flick --no-quarantine
flick install                    # wires hooks into ~/.claude/settings.json
```

`--no-quarantine` skips the "Apple could not verify" warning. The app isn't
notarized yet.

### From source

```bash
./scripts/build-app.sh          # builds /Applications/Flick.app and the flick CLI
open /Applications/Flick.app    # menu-bar icon appears, no Dock icon
flick install                   # wires hooks into ~/.claude/settings.json
```

Restart your Claude Code sessions afterwards so they pick up the hooks.

`flick install` backs up your existing `settings.json` first and tells you where
the backup went. Removal is symmetric: `flick uninstall` strips only the entries
tagged `_flick` and leaves anything you wrote by hand alone.

### Check it worked

```bash
flick status
# socket:   ~/Library/Application Support/Flick/inbox.sock
# app:      listening
# hooks:    installed
# database: ~/Library/Application Support/Flick/inbox.sqlite3
```

Want to see a card without waiting for a real prompt?

```bash
flick test            # a benign approval
flick test --risky    # one that trips the destructive-command classifier
```

### One setting worth changing

Go to System Settings → Notifications → Flick and set the alert style to
**Persistent** (older macOS calls it Alerts).

The default style vanishes after about five seconds, which isn't much use for
something you're meant to answer. Persistent waits for you, and hovering over
the banner reveals the Allow and Deny buttons.

## The agent dashboard

Open the popover and every session you have running is listed:

```
Agents                              1 waiting

Claude Code · routa
Waiting for approval · 38s
src/server/middleware/auth.ts

Claude Code · flick
Working · 4m 12s
scripts/build-app.sh

Claude Code · api-gateway
Finished · 1m 47s
```

Four states, and only four, because the question you're asking is "does anything
need me?":

| State | Means |
|---|---|
| **Working** | Running. Nothing wanted from you. The label shimmers so you can tell at a glance. |
| **Waiting** | Stopped, and it can't continue without you. |
| **Finished** | Its turn ended. |
| **Error** | It stopped on something that went wrong. |

The timer counts from the moment the status *changed*, not from the last event —
a session that's been working four minutes keeps counting rather than resetting
every time a tool call goes by. Anything waiting on you sorts to the top. Click a
row to jump straight to the window it's running in.

Sessions that end stay on screen for half a minute before they disappear, so you
see a run land on "Finished" instead of watching a row vanish mid-glance.

The file line shows whatever the agent last had its hands on. It only updates
when an event actually reaches Flick, so a session running in `acceptEdits` mode
— which never prompts — won't show one.

## What actually works

| Capability | Claude Code | Notes |
|---|---|---|
| Menu-bar badge and native notification | ✅ | Banner carries Allow/Deny buttons |
| Approval card with the exact command | ✅ | Never summarised or truncated away |
| Allow / Deny from the menu bar | ✅ | Real decision returned to the agent |
| Allow for this session | ✅ | Capped at the risk level it was granted on, never destructive commands |
| Reply with text to a blocked tool call | ✅ | Denies the call, hands Claude your words as the reason |
| Live agent dashboard | ✅ | Status, elapsed time, current file, click to jump |
| Jump to the originating session | ✅ | Exact tab in Terminal and iTerm, app-level for VS Code |
| Multi-session routing | ✅ | Each response goes back to the connection it came from |
| Session and request history | ✅ | SQLite, pruned after 14 days |
| Launch at login | ✅ | On by default, and honest about it if the system refuses |
| Reply to an idle session | ⚠️ | Needs a recent Claude Code with inbound messages enabled |
| Codex CLI | ❌ | Not built — Codex wasn't installed to verify against |
| Other terminal agents (PTY bridge) | ❌ | Not built |

There's a real difference between the two halves of this. Telling you something
happened is easy and works almost anywhere. Letting you *answer* needs a proper
two-way channel. For Claude Code that channel is a blocking `PreToolUse` hook,
and it is the only one — a message pushed at a session can't answer a permission
prompt that's already waiting.

## How it's put together

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
  "target": "Sources/App/Main.swift",  // the file it's touching, when there is one
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
silently auto-approves anything, and your agent's own sandbox and permission
model are left exactly as they were.

## Three decisions that make it usable

**1. It fails open, always.**

If the app isn't running, the socket is stale, or the payload won't parse, the
hook prints no decision and exits 0 — which restores Claude Code's normal
permission prompt. Flick can annoy you. It cannot wedge a coding session.

That's also why the timeout is safe. A `PreToolUse` hook that times out doesn't
block the tool call; Claude falls through to its own prompt. A card you never
answer costs you nothing beyond the wait.

Worth knowing if you're building something similar: returning
`permissionDecision: "ask"` does **not** restore the standard prompt. Omitting
the decision entirely is what does, and that's what the helper emits for defer,
timeout, and every failure path.

**2. It stays quiet about things you already allowed.**

A naive hook would raise a card for every `npm install`. This machine has well
over a hundred `permissions.allow` rules, and Claude would never have prompted
for most of them. So the helper re-evaluates those rules itself — prefix rules,
exact rules, path globs — and skips anything already permitted, along with
`bypassPermissions`, `plan`, and `acceptEdits` for edit tools. Read-only tools
are never intercepted at all.

The matcher is deliberately conservative, and it fails in a safe direction. It
can only decide to *skip*, and skipping hands the call back to Claude's real
permission check. A wrong "this is allowed" costs you a missed notification,
never an unauthorised execution.

Getting it to agree with the shell took more care than expected. A compound
command only counts as allowed when *every* segment is, or `git status && rm -rf /`
would ride in on its first half. Newlines separate commands just like `&&` does.
A lone `&` separates too, though `2>&1` and `&>log` are redirects and must not.
Heredoc bodies are data rather than commands, so they're skipped instead of
judged — but anything chained onto the opening line still gets checked. And
`$((a<<b))` is arithmetic, not a heredoc. Each of those was a real way for a
command to slip past unnoticed, and each has a test.

**3. Destructive commands are treated differently.**

A classifier labels `rm -rf`, `sudo`, `curl … | sh`, force pushes, `drop table`,
secrets paths and similar as destructive. Those cards lose the "Allow for
session" button, lose the one-click Allow on the notification banner, and a
session-wide allow never covers them.

Approving something dangerous should never be one piece of muscle memory.

## Sound and notifications

Everything you might be waiting on makes a sound — including a session simply
finishing, which is the one people walk away for. Each event sounds different so
you can tell what happened without looking: a decision needed uses your system
alert sound, a finished run is softer, and destructive commands and errors are
deliberately harder to ignore.

Flick plays these itself rather than attaching them to the notification. A
notification sound is swallowed by any Do Not Disturb — including the one macOS
turns on by itself while your display sleeps, which is exactly when you've
stepped away and most need to hear it.

## Verified

Tested against the live hook contract, not just at unit level:

- Fail-open with the app stopped, giving `{"hookSpecificOutput":{"hookEventName":"PreToolUse"}}` and exit 0
- Blocking approval with the app running and no answer, held exactly 6s, then fell back to the terminal prompt
- Non-blocking notification acked in 67 ms, so the agent is never slowed down
- Allowlisted `npm install left-pad` produced no card — the matcher stayed silent
- Non-allowlisted `curl … | sh` surfaced, classified `high`, "Allow for session" withheld
- Decision round trip, where a stub broker answering `allow` produced `permissionDecision: "allow"`
- tty and terminal detection, giving `/dev/ttys004` and `com.microsoft.VSCode` via a process-tree walk
- Messaging channel emitting `{"type":"auth"}` then `{"type":"message"}`, verified on the wire
- Notification banner carrying working Allow and Deny buttons
- Popover staying on screen in a full-screen space, where the auto-hiding menu bar used to drag its top off the display
- Dashboard driven through Working, Waiting and Finished with live hook events, including the grace period on session end

Not yet verified: delivery of a reply into a *live* remote Claude session. The
wire format is confirmed against a stub, but acceptance depends on that
session's inbound-message setting.

## Layout

```
Sources/InboxCore/        Protocol, socket transport, SQLite store, risk classifier,
                          session status, markdown flattening, process-tree tty detection
Sources/FlickApp/         MenuBarExtra app: broker, inbox UI, approval cards,
                          agent dashboard, notifications, jump-to-session
Sources/flick/            CLI: hook adapter, permission-rule matcher, installer
Tests/FlickTests/         Permission matching, panel placement, event classification,
                          session status, markdown flattening
scripts/build-app.sh      Bundles and ad-hoc signs the .app, links the CLI
```

Run the tests with `swift test`. That needs a full Xcode install — XCTest doesn't
ship with the Command Line Tools alone, so `swift test` fails at `import XCTest`
without it. `swift build` works either way.

Why an `.app` bundle rather than a bare SwiftPM executable: `MenuBarExtra` and
`UserNotifications` both need a real bundle identifier. Without one the app falls
back to AppleScript banners, which have no buttons.

## Roadmap

What's next, in order:

- **A Codex adapter.** Using Codex's own notification and approval surfaces where
  the installed version exposes them, and a PTY bridge where it doesn't.
  Deliberately not written yet, because Codex isn't installed here — and an
  adapter written against a guessed interface is exactly the "claiming universal
  support before each adapter is proven" trap.
- **More polish.** Keyboard shortcuts, project icons, and a history view (the
  data is already stored).
- **More agents.** Gemini CLI, OpenCode, Cursor, and a VS Code extension.

The seams are ready. `AgentKind` is open-ended, so an unknown agent that speaks
the canonical event renders and routes correctly without anyone touching the
broker or the UI.

## Known gaps

- Focusing an exact tab uses AppleScript, so the first jump asks for Automation
  permission. Denying it still leaves app-level focus working.
- VS Code's integrated terminal has no tab-level scripting, so jumping there
  activates the window rather than the specific terminal.
- The `Stop` hook fires on every turn. It's installed, and the inbox treats it as
  a low-key "finished" event rather than a demand for attention.
- MCP tools aren't intercepted by default. Add a `/^mcp__/` matcher to the
  `PreToolUse` block by hand if you want them.
- Session status is kept in memory, so restarting Flick reseeds every live
  session as "Working" rather than restoring what it was doing.
- The app is ad-hoc signed, so notifications can't be marked time-sensitive. That
  needs a paid Apple Developer account, and without it a Focus mode will hold
  banners back. The sound still plays.
