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

`show` opens a temporary top overlay inside tmux and closes when you press any key. Use `--plain` to print in the current pane, or `--no-wait` for scripts.
`top` opens Threadline in tmux's top status area.
`toggle` shows the top status area if hidden, or restores your previous tmux status layout if visible.

Example tmux bindings:

```tmux
bind-key t run-shell 'TMUX_PANE=#{pane_id} threadline show'
bind-key T run-shell 'TMUX_PANE=#{pane_id} threadline summarize && TMUX_PANE=#{pane_id} threadline show'
bind-key b run-shell 'TMUX_PANE=#{pane_id} threadline toggle'
```
