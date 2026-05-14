# Threadline

Threadline is a small terminal companion that summarizes what you are currently working on in a CLI session.

The first target is a tmux-based workflow:

```bash
threadline summarize
threadline show
threadline watch
```

Planned flow:

```text
tmux pane/git context -> LLM summary -> local cache -> tmux popup
```

Example tmux bindings:

```tmux
bind-key t display-popup -E -w 70% -h 40% 'threadline show'
bind-key T display-popup -E -w 70% -h 40% 'threadline summarize && threadline show'
```

