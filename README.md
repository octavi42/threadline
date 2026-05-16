# Threadline

Threadline has two pieces:

1. **`threadline` (Python)** — records a terminal session and summarizes the current work thread.
2. **`threadline-overlay` (Swift, macOS)** — a small app window that shows live context from your Claude Code, Codex CLI, and Cursor sessions. See [`overlay/README.md`](overlay/README.md).

---

Threadline is a CLI companion that records a terminal session and summarizes the current work thread.

The primary workflow is tmux-free:

```bash
threadline session
```

This starts your normal shell inside a PTY, reserves a fixed Threadline panel at the top of the terminal, and records the terminal stream to:

```text
~/.local/state/threadline/sessions/
```

Inside that shell, work normally:

```bash
vim
git
codex
claude
npm test
```

Then ask Threadline what is going on:

```bash
threadline show
threadline summarize
threadline show --compact --no-wait
```

## Install

From the project directory:

```bash
python -m pip install -e .
```

## Commands

```bash
threadline session          # start a tracked shell with a fixed top panel
threadline session --no-panel
threadline show             # show current summary, wait for a key
threadline summarize        # refresh summary cache
threadline watch            # redraw summary periodically
threadline reset            # clean legacy tmux Threadline panes/options
```

`threadline session --shell zsh` can run a specific shell.

### Agent history (Claude / Codex / Cursor)

A background tailer watches agent session JSONL files and snapshots tracked git files on new activity. State lives under `~/.local/state/threadline/snapshots/`.

```bash
threadline history-daemon   # run the tailer (leave this running)
threadline log              # list sessions with snapshot counts
threadline diff <short-id>  # what changed within one session
threadline diff <a> <b>     # compare two sessions (cross-agent OK)
```

The macOS overlay surfaces terminated sessions with file snapshots as **HCD** / **HCX** / **HCU** rows (last 24h). Live tabs stay **CLD** / **CDX** / **CUR**.

## Notes

Threadline still has legacy tmux commands from the prototype, but tmux is no longer required for session capture.
