# Threadline

**See what your AI coding agents are doing — without leaving your flow.**

Threadline is a small macOS overlay that surfaces live context from **Claude Code**, **Codex CLI**, and **Cursor** in one window: last message, model, project path, and how long each session has been running. Toggle it from anywhere with a global hotkey.

```
┌─ Threadline ───────────────────────────────────────── 15:23 ─┐
│ Claude  [assistant] writing the panel now…                  │
│         ~/Projects/my-app · claude-opus-4-7 · 12s           │
│ Codex   [assistant] refactoring auth middleware             │
│         ~/Projects/my-app · gpt-5 · 4m                      │
│ Cursor  workspace active                                      │
│         ~/Projects/my-app · 1d                              │
└──────────────────────────────────────────────────────────────┘
```

## Why Threadline

You run multiple AI coding sessions across terminals and editors. Threadline answers:

> **Which agent needs me right now, and what is it working on?**

It reads session logs on your Mac (no cloud upload), scopes context to the terminal tab you are in when shell hooks are installed, and lets you **jump back** to the right terminal or editor with one action.

## Features

- **Multi-agent inbox** — Claude Code, Codex CLI, and Cursor in one list
- **Per-tab scoping** — shell hooks tie activity to the focused terminal tab (Ghostty, Terminal.app, iTerm2)
- **Global hotkey** — default **⌃⌥⌘T** toggles the window (no Accessibility permission required)
- **Jump back** — focus the terminal or editor for the selected session
- **Optional local AI** — Ollama for summaries when available; falls back to CLI or rules
- **Privacy-first** — reads local files only; no account, no telemetry

## Requirements

| | |
|---|---|
| **OS** | macOS 13 (Ventura) or later |
| **Build** | Xcode 14+ or Swift 5.9+ command-line tools |
| **Agents** | At least one of: Claude Code, Codex CLI, or Cursor (for data to appear) |

No Accessibility, Input Monitoring, or Screen Recording prompts for normal use. macOS may ask for **Automation** permission the first time you use jump-back to a terminal.

## Install

### One-liner (clone + build)

```bash
curl -fsSL https://raw.githubusercontent.com/octavi42/threadline/main/overlay/install.sh | bash
```

This clones the repo, builds a release binary, installs `threadline-overlay` to `~/.local/bin`, registers a LaunchAgent, and starts the daemon. Add `~/.local/bin` to your `PATH` if the installer prints a hint.

### From a git clone

```bash
git clone https://github.com/octavi42/threadline.git
cd threadline/overlay && ./install.sh
```

Fork or branch installs can override the source:

```bash
THREADLINE_INSTALL_REPO=https://github.com/you/threadline.git \
THREADLINE_INSTALL_REF=main \
  curl -fsSL https://raw.githubusercontent.com/octavi42/threadline/main/overlay/install.sh | bash
```

## Quick start

```bash
threadline-overlay show      # open the window
threadline-overlay toggle    # show/hide (same as ⌃⌥⌘T)
threadline-overlay jump      # focus selected session's terminal/editor
threadline-overlay status    # daemon pid, agents, window frame
threadline-overlay uninstall # remove LaunchAgent + binary
```

After install, open a new terminal tab or run a command so the shell hook registers your cwd. Threadline rescans agent session files every few seconds.

## How it works

```
~/.claude/projects/          ─┐
~/.codex/sessions/           ─┼─► threadline-overlay daemon ─► NSWindow UI
Cursor workspaceStorage/     ─┘         ▲
                                        │ Unix socket (~/.threadline/overlay.sock)
~/.zshrc / ~/.bashrc hooks ─────────────┘  (pid, cwd, tty per prompt)
```

The overlay is a single Swift binary: a long-lived **daemon** (window + polling) plus a **CLI** for toggle, jump, and status. See **[overlay/README.md](overlay/README.md)** for architecture, shell hooks, Ollama config, and hotkey overrides.

## Documentation

| Doc | Description |
|-----|-------------|
| [overlay/README.md](overlay/README.md) | Install details, CLI, shell hooks, optional Ollama |
| [docs/](docs/) | Product direction and design notes |

## Repository layout

```
threadline/
├── overlay/          # macOS app (Swift) — this is what you install
│   ├── install.sh
│   ├── Sources/
│   └── Tests/
└── docs/             # vision and design (not required to run the app)
```

## Contributing

Contributions are welcome. Build and test from `overlay/`:

```bash
cd overlay
swift build
swift test
```

`CONTRIBUTING.md` and CI are coming as the project opens up. Open an [issue](https://github.com/octavi42/threadline/issues) for bugs and ideas.

## License

[MIT License](LICENSE) — Copyright (c) 2026 [octavi42](https://github.com/octavi42).
