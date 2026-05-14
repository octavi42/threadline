# Threadline

Threadline is a small terminal companion that summarizes what you are currently working on in a CLI session.

The first target is a tmux-based workflow:

```bash
threadline summarize
threadline show
threadline watch
threadline toggle
```

Planned flow:

```text
tmux pane/git context -> LLM summary -> local cache -> tmux popup
```

## Try It

Prerequisites for the popup workflow:

```bash
brew install tmux
```

From the project directory:

```bash
python -m pip install -e .
threadline summarize
threadline show --no-wait
```

From inside tmux:

```bash
threadline show
threadline top
threadline toggle
```

`show` waits for one key before closing when it is attached to a real terminal. Use `--no-wait` for scripts.
`top` opens a fixed compact Threadline pane above the current pane.
`toggle` opens the fixed top pane if hidden, or closes it if visible.

Example tmux bindings:

```tmux
bind-key t display-popup -E -w 70% -h 40% 'threadline show'
bind-key T display-popup -E -w 70% -h 40% 'threadline summarize && threadline show'
bind-key b run-shell 'threadline toggle'
```
