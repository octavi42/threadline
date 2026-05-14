# threadline-overlay

A small macOS floating panel that sits on top of every Space and shows the live
context of your AI coding sessions: Claude Code, Codex CLI, and Cursor.

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
panel from anywhere. No permission prompt — it's registered via Carbon's
`RegisterEventHotKey`. Override by setting `THREADLINE_HOTKEY` in the
LaunchAgent environment (e.g. `ctrl+opt+cmd+\\`, `cmd+shift+f19`).

```bash
threadline-overlay toggle    # enable/disable follow mode
threadline-overlay show      # peek for 8s
threadline-overlay hide      # disable follow + hide
threadline-overlay refresh   # rescan session files now
threadline-overlay status    # daemon pid, panel frame, current anchor
threadline-overlay quit      # stop daemon
threadline-overlay uninstall # remove LaunchAgent + binary
```

The first invocation auto-installs the LaunchAgent if `install.sh` was skipped.

## How per-tab scoping works

When `install` runs, a marker block is appended to `~/.zshrc` and `~/.bashrc`:

```sh
# >>> threadline-overlay >>>
__threadline_touch() {
    "/Users/you/.local/bin/threadline-overlay" touch --cwd "$PWD" --pid $$ >/dev/null 2>&1 &
    disown >/dev/null 2>&1 || true
}
# … wires it into precmd_functions / PROMPT_COMMAND
# <<< threadline-overlay <<<
```

Each prompt pings the daemon with `(pid, cwd)`. The daemon walks the shell's
parent chain via `sysctl(KERN_PROC_PID)` and finds which terminal app owns it.
For the frontmost terminal, the most recently-touched shell's cwd becomes the
scope; the source readers then filter to sessions matching that cwd.

Result: switch tabs → next prompt in the focused tab updates the scope →
panel flips. Open a new window → its first prompt registers. `uninstall`
strips the marker block.

Falls back to global newest when no touch matches (e.g. no shell hook
installed, or focused window is Cursor/VS Code).

## How it follows the terminal

When follow mode is on, the daemon polls the frontmost app at 15 Hz. If it's
a known terminal (Terminal.app, iTerm2, Ghostty, Warp, Alacritty, kitty,
WezTerm, Hyper, Tabby) or a known editor (Cursor, VS Code), the panel is
re-pinned to that window's top edge with matching width. Anywhere else
frontmost → panel hides until you switch back.

The window geometry comes from `CGWindowListCopyWindowInfo`, which exposes
owner PID and bounds without prompting for Accessibility, Input Monitoring,
or Screen Recording.

Add a terminal not listed above by editing the `targetBundleIDs` set in
`Sources/threadline-overlay/WindowFinder.swift`.

## What it reads

- **Claude Code:** newest `*.jsonl` under `~/.claude/projects/`. Pulls last
  assistant/user text, model, cwd, timestamp.
- **Codex CLI:** newest `rollout-*.jsonl` under `~/.codex/sessions/YYYY/MM/DD/`.
  Pulls last `agent_message` / `user_message`, plus cwd from `session_meta`.
- **Cursor:** newest `state.vscdb` under
  `~/Library/Application Support/Cursor/User/workspaceStorage/`. Surfaces the
  active workspace folder and mtime (v0 — full chat parsing is TODO).

Sources are re-scanned every 3 seconds.

## How the float works

`NSPanel` with `styleMask: [.nonactivatingPanel, .hudWindow, .utilityWindow,
.titled, .fullSizeContentView, .resizable]`, `level = .statusBar`, and
`collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`.
The panel never steals focus from your terminal / editor.

`show` dismisses on the next app switch (via `NSWorkspace` activation
notifications — no permission) or after an 8-second safety timeout.

## Architecture

```
threadline-overlay (single binary)
├── CLI mode      : short-lived, sends a 1-line command over a Unix socket
└── daemon mode   : NSApp + NSPanel + socket listener at ~/.threadline/overlay.sock
                    ├── SessionModel (Combine, 3s poll)
                    │     ├── ClaudeSource  (~/.claude/projects/*.jsonl)
                    │     ├── CodexSource   (~/.codex/sessions/**/*.jsonl)
                    │     └── CursorSource  (workspaceStorage state.vscdb)
                    └── OverlayController (NSPanel + show/hide/show-once)
```

## Roadmap

- Parse Cursor `cursorDiskKV` bubbles for real chat text.
- Drag-to-reposition + persisted frame.
- Token/usage display per source.
- Optional: hook into the existing Python `threadline` CLI for PTY-recorded
  shell context.
