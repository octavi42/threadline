# Threadline Product Ideas

Threadline's strongest position is not another chat UI. It can become a local,
cross-tool control layer for AI coding sessions: always visible, private by
default, and focused on what needs human attention next.

## 1% Features

### Attention Radar

Rank sessions by whether they need the user now:

- awaiting approval
- asked a question
- tests failed
- stuck or no output
- finished and ready to review
- dirty files
- high cost
- context near limit

This should drive sorting, colors, notifications, and the default target for
keyboard actions.

### One-Key Jump Back

Focus the exact terminal, editor, tab, or session from the overlay. The ideal
flow is:

- select a session in Threadline
- press Enter
- macOS brings the owning app/window forward
- the user lands back where the agent is running

Useful companion actions:

- `F` follows live logs
- `R` prepares a resume prompt
- `S` refreshes summary
- `D` opens a diff digest

### Diff Digest

For each project, summarize what changed:

- branch
- dirty file count
- edited files
- last command
- tests run
- test result
- risk level

The human-readable version should answer: "What changed, and is it safe to
review?"

### Actionable End States

Replace generic idle/running labels with specific states:

- ready to review
- needs approval
- blocked on failing test
- waiting for your answer
- still working
- probably stuck

Each state should include a recommended next action.

### Universal Session Timeline

Merge activity from Claude, Codex, Cursor, shell commands, git changes, and
test results into a single per-project timeline.

Example:

```text
09:41 Claude edited parser
09:43 npm test failed
09:45 Codex fixed import
09:48 3 files dirty
```

### Follow-Up Prompt Generator

Generate a precise continuation prompt for any session:

```text
Continue from here. You changed X/Y, tests are failing with Z. Fix only that
and rerun npm test.
```

### Local Hooks Installer

Add a `doctor` or `install-hooks` command that configures and verifies local
integrations:

- shell prompt hook
- Claude Code statusline/hooks
- optional git hooks
- session ingestion health

### Cost And Context Burn Meter

Show cost, runtime, context usage, and warnings:

- context almost full
- expensive loop
- long-running with no file changes
- high cost per minute

### Remote Nudge

Start with simple integrations rather than a full mobile app:

- ntfy
- Pushover
- Slack
- webhook

Notify only on actionable transitions.

### Project-Level Agent Board

Group by repository first, tool second:

```text
threadline-folder-sessions
Claude   running   writing panel
Codex    awaiting  approval: npm test
Cursor   active    workspace touched 4m ago
Git      6 dirty   branch feature/session-board
```

## First Implementation Bet

Build Attention Radar plus Actionable End States before expanding the command
surface. Those features make Threadline feel smarter immediately and create the
right default target for One-Key Jump Back.
