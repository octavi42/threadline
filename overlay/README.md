# threadline-overlay

A small macOS app window that shows the live context of your AI coding
sessions: Claude Code, Codex CLI, and Cursor.

```
┌─ Threadline ───────────────────────────────────────── 15:23 ─┐
│ Claude  [assistant] writing the panel now…                  │
│         ~/Projects/threadline · claude-opus-4-7 · 12s        │
│ Codex   [assistant] `/Users/.../threadline`                  │
│         ~/Projects/threadline · openai · 4m                  │
│ Cursor  workspace active                                     │
│         ~/Dev/contributions/geomind-mcp · 1d                 │
└──────────────────────────────────────────────────────────────┘
```

## Install (one command)

Requires Xcode 14+ / Swift 5.9+.

```bash
cd overlay && ./install.sh
```

That builds a release binary, copies it to `~/.local/bin/threadline-overlay`,
registers a LaunchAgent so the daemon survives logout/login, and starts it.
Add `~/.local/bin` to your `PATH` if it isn't there yet.

No macOS permission prompts. No Accessibility, no Input Monitoring, no Screen
Recording.

## Use

Default global hotkey: **⌃⌥⌘T** (Control + Option + Command + T) toggles the
window from anywhere. No permission prompt — it's registered via Carbon's
`RegisterEventHotKey`. Override by setting `THREADLINE_HOTKEY` in the
LaunchAgent environment (e.g. `ctrl+opt+cmd+\\`, `cmd+shift+f19`).

```bash
threadline-overlay toggle    # show/hide the app window
threadline-overlay show      # show the app window
threadline-overlay hide      # hide the app window
threadline-overlay refresh   # rescan session files now
threadline-overlay jump      # focus the selected agent's terminal/editor
threadline-overlay status    # daemon pid, window frame, agent count
threadline-overlay quit      # stop daemon
threadline-overlay uninstall # remove LaunchAgent + binary
```

The first invocation auto-installs the LaunchAgent if `install.sh` was skipped.

## How per-tab scoping works

When `install` runs, a marker block is appended to `~/.zshrc` and `~/.bashrc`:

```sh
# >>> threadline-overlay >>>
__threadline_touch() {
    "/Users/you/.local/bin/threadline-overlay" touch --cwd "$PWD" --pid $$ --tty "$(tty 2>/dev/null || true)" >/dev/null 2>&1 || true
}
# … wires it into precmd_functions / PROMPT_COMMAND
# <<< threadline-overlay <<<
```

Each prompt pings the daemon with `(pid, cwd, tty)`. The daemon walks the shell's
parent chain via `sysctl(KERN_PROC_PID)` and finds which terminal app owns it.
For Ghostty, the daemon also records the focused terminal surface ID at prompt
time so same-directory tabs can still be distinguished after a restart.

Press **Return** in the Threadline window, or run `threadline-overlay jump`, to
focus the selected session's owning terminal/editor. Ghostty records its exact
terminal surface ID and focuses that surface. Terminal.app and iTerm2 try to
select the exact tab by matching the recorded TTY. macOS may ask for Automation
permission the first time one of these exact-focus paths runs. Other terminals
fall back to activating the owning app/window.

Result: switch tabs → next prompt in the focused tab updates the scope →
window context updates. Open a new window → its first prompt registers. `uninstall`
strips the marker block.

Falls back to global newest when no touch matches (e.g. no shell hook
installed, or focused window is Cursor/VS Code).

## What it reads

- **Claude Code:** newest `*.jsonl` under `~/.claude/projects/`. Pulls last
  assistant/user text, model, cwd, timestamp.
- **Codex CLI:** newest `rollout-*.jsonl` under `~/.codex/sessions/YYYY/MM/DD/`.
  Pulls last `agent_message` / `user_message`, plus cwd from `session_meta`.
- **Cursor:** newest `state.vscdb` under
  `~/Library/Application Support/Cursor/User/workspaceStorage/`. Surfaces the
  active workspace folder and mtime (v0 — full chat parsing is TODO).

Sources are re-scanned every 3 seconds.

## How the window works

The UI is a regular resizable macOS `NSWindow` with a normal window level. It
opens at the last saved size and position, or centered on the main screen the
first time. It does not pin itself to the top of another app and it does not
join every Space.

## Architecture

```
threadline-overlay (single binary)
├── CLI mode      : short-lived, sends a 1-line command over a Unix socket
└── daemon mode   : NSApp + NSWindow + socket listener at ~/.threadline/overlay.sock
                    ├── SessionModel (Combine, 3s poll)
                    │     ├── ClaudeSource  (~/.claude/projects/*.jsonl)
                    │     ├── CodexSource   (~/.codex/sessions/**/*.jsonl)
                    │     └── CursorSource  (workspaceStorage state.vscdb)
                    └── OverlayController (NSWindow + show/hide)
```

## Optional local AI (Ollama)

Session summaries and work-status labels try **Ollama first** when it is running
on this Mac. No API key required. If Ollama is not installed or not running,
Threadline falls back to your `claude -p` / `codex exec` CLIs, then rule-based
status.

```bash
brew install ollama
ollama pull qwen2.5:3b
ollama serve   # or leave the Ollama app running
```

Configure via environment or `~/.threadline/config.json`:

| Key | Default |
|-----|---------|
| `THREADLINE_OLLAMA_HOST` / `ollama_host` | `http://127.0.0.1:11434` |
| `THREADLINE_OLLAMA_MODEL` / `ollama_model` | `qwen2.5:3b` |
| `THREADLINE_DISABLE_OLLAMA=1` | skip local AI |

## Roadmap

- Parse Cursor `cursorDiskKV` bubbles for real chat text.
- Token/usage display per source.
- Optional: hook into the existing Python `threadline` CLI for PTY-recorded
  shell context.
