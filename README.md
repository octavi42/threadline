# Threadline

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

## Notes

Threadline still has legacy tmux commands from the prototype, but tmux is no longer required for session capture.
