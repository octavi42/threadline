# Threadline

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)](overlay/Package.swift)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)](overlay/Package.swift)
[![Release](https://img.shields.io/github/v/release/octavi42/threadline?label=release)](https://github.com/octavi42/threadline/releases/latest)

**Which AI session is safe to review?**

Threadline is a local macOS overlay — a **pre-PR trust inbox** for **Claude Code**, **Codex CLI**, and **Cursor**. When several agents work on the same repo, it shows who needs you, who is risky, who is ready, and when two agents disagree on the same file.

Toggle from anywhere with **⌃⌥⌘T**. Jump back to the exact terminal tab or Cursor workspace in one action.

```bash
curl -fsSL https://raw.githubusercontent.com/octavi42/threadline/main/overlay/install.sh | bash
```

## Demo

<!-- After you record: add docs/demo.gif or docs/demo.png and uncomment the line below -->
<!-- ![Threadline inbox showing trust statuses and cross-agent conflicts](docs/demo.gif) -->

```
┌─ INBOX ──────────────────────────────────────────────────────┐
│ ▾ my-app                                    3                  │
│   1 Needs you · 1 Risky · 1 Ready                              │
│     CLA  Needs you    waiting for approval                     │
│     CDX  Risky        5 files changed, no tests                │
│     CUR  Ready        tests passed                               │
├─ CONFLICTS ──────────────────────────────────────────────────┤
│   auth.ts — Claude + Codex                                     │
│   Claude: Ready · Codex: Risky  →  Review Claude first         │
└────────────────────────────────────────────────────────────────┘
```

## The problem

You run Claude in one terminal, Codex in another, Cursor in a third. Ten minutes later you do not know which session is done, stuck, waiting for approval, or safe to turn into a PR.

Threadline reads agent session logs **on your Mac only** — no account, no cloud sync, no telemetry — and turns them into a small set of trust states:

| Status | Meaning |
|--------|---------|
| **Needs you** | Blocked on approval or input |
| **Stuck** | Same error repeating |
| **Tests failed** | Tests ran and failed |
| **Risky** | Code changed without enough verification |
| **Ready** | Reasonable to review |
| **Working** | Still in progress |

Per project you get a rollup (e.g. `1 Needs you · 2 Risky · 1 Ready`) and a **CONFLICTS** strip when two agents touched the same file with different trust.

## Features

- **Pre-PR trust inbox** — status, reason, and next action per session; folder rollup across agents
- **Cross-agent conflicts** — same file, different trust → which session to review first
- **Stuck-loop detection** — repeated tool errors surfaced as **Stuck**
- **Multi-agent** — Claude Code, Codex CLI, and Cursor in one list
- **Exact jump-back** — Ghostty (surface / cwd), Terminal / iTerm (TTY), Cursor (workspace); no false “success” when the tab cannot be found
- **Per-tab scoping** — shell hooks tie activity to the focused terminal tab (Ghostty, Terminal.app, iTerm2)
- **Global hotkey** — **⌃⌥⌘T** toggles the window (no Accessibility permission for normal use)
- **Optional local AI** — Ollama for summaries when available; deterministic rules otherwise
- **Privacy-first** — local files only

> **Note:** This repo is the **Threadline macOS overlay** (`octavi42/threadline`). It is unrelated to [threadline.to](https://threadline.to/) (agent memory) and other projects named Threadline.

## Requirements

| | |
|---|---|
| **OS** | macOS 13 (Ventura) or later |
| **Build** | Xcode 14+ or Swift 5.9+ command-line tools (only if building from source) |
| **Agents** | At least one of: Claude Code, Codex CLI, or Cursor |

No Accessibility, Input Monitoring, or Screen Recording prompts for normal use. macOS may ask for **Automation** the first time you jump back to a terminal.

## Install

### One-liner (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/octavi42/threadline/main/overlay/install.sh | bash
```

Downloads a **prebuilt binary** from the [latest release](https://github.com/octavi42/threadline/releases/latest) when available (Apple Silicon or Intel). Otherwise builds from source.

Installs `threadline-overlay` to `~/.local/bin`, registers a LaunchAgent, and starts the daemon. Add `~/.local/bin` to your `PATH` if the installer prints a hint.

Pin a version:

```bash
THREADLINE_VERSION=v0.1.1 \
  curl -fsSL https://raw.githubusercontent.com/octavi42/threadline/main/overlay/install.sh | bash
```

Force a source build:

```bash
THREADLINE_BUILD_FROM_SOURCE=1 \
  curl -fsSL https://raw.githubusercontent.com/octavi42/threadline/main/overlay/install.sh | bash
```

### Manual download

1. Open [Releases](https://github.com/octavi42/threadline/releases)
2. Download `threadline-overlay-macos-arm64.tar.gz` (Apple Silicon) or `threadline-overlay-macos-x86_64.tar.gz` (Intel)
3. Extract and run:

```bash
tar -xzf threadline-overlay-macos-arm64.tar.gz
./threadline-overlay install
```

### From a git clone

```bash
git clone https://github.com/octavi42/threadline.git
cd threadline/overlay && ./install.sh
```

## Quick start

```bash
threadline-overlay show      # open the window
threadline-overlay toggle    # show/hide (same as ⌃⌥⌘T)
threadline-overlay jump      # focus selected session's terminal/editor
threadline-overlay status    # daemon pid, agents, window frame
threadline-overlay uninstall # remove LaunchAgent + binary
```

After install, open a **new terminal tab** or run a command so the shell hook registers your cwd and TTY. Threadline rescans agent session files every few seconds.

**Good demo setup for video/posts:** run Claude + Codex on the same repo, make one **Ready** (tests pass) and one **Risky** (edits without tests), optionally touch the same file from both — then hotkey → inbox → conflict → jump back.

## How it works

```
~/.claude/projects/          ─┐
~/.codex/sessions/           ─┼─► threadline-overlay daemon ─► trust inbox UI
Cursor workspaceStorage/     ─┘         ▲
                                        │ Unix socket (~/.threadline/overlay.sock)
~/.zshrc / ~/.bashrc hooks ─────────────┘  (pid, cwd, tty, terminal surface per prompt)
```

Evidence from JSONL tails and git signals feeds **WorkStatusResolver** (rules) with optional Ollama for briefs. The overlay is one Swift binary: daemon + CLI. Details: **[overlay/README.md](overlay/README.md)**.

## Documentation

| Doc | Description |
|-----|-------------|
| [overlay/README.md](overlay/README.md) | CLI, shell hooks, Ollama, hotkey overrides |
| [docs/launch-video-script.md](docs/launch-video-script.md) | 30s / 60s recording script |
| [docs/threadline-v1-direction.md](docs/threadline-v1-direction.md) | Product direction (WIP notes) |

## Repository layout

```
threadline/
├── overlay/          # macOS app (Swift) — install this
│   ├── install.sh
│   ├── Sources/
│   └── Tests/
└── docs/
```

## Contributing

```bash
cd overlay
swift build
swift test
```

CI runs on every push to `main`. See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md) for reports and setup.

## License

[MIT License](LICENSE) — Copyright (c) 2026 [octavi42](https://github.com/octavi42).
