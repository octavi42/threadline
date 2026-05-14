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
threadline reset
```

`show` opens a temporary top overlay inside tmux and closes when you press any key. Use `--plain` to print in the current pane, or `--no-wait` for scripts.
`top` opens a managed multi-line Threadline pane above the current pane.
`toggle` shows that top Threadline pane if hidden, or removes it and returns focus to your work pane if visible.
Because tmux has no persistent multi-line overlay, this reserves a few rows at the top of the layout.
`reset` removes stale Threadline panes and restores tmux display options.

Example tmux bindings:

```tmux
bind-key t run-shell 'TMUX_PANE=#{pane_id} threadline show'
bind-key T run-shell 'TMUX_PANE=#{pane_id} threadline summarize && TMUX_PANE=#{pane_id} threadline show'
bind-key b run-shell 'TMUX_PANE=#{pane_id} threadline toggle'
```
