# Agentic Versioning Ledger

Threadline should evolve from a session/file diff viewer into an agentic
version ledger: Git remains the storage engine for code snapshots, while
Threadline explains the agent work that produced those snapshots.

## Core Thesis

Traditional version control answers:

```text
what files changed?
what lines changed?
who committed?
when?
```

Agentic versioning must also answer:

```text
what goal was the agent pursuing?
what prompt or issue created the work?
which agent/model/runtime changed it?
what context did it inspect?
what tool calls produced each patch?
what commands/tests/checks were run?
what evidence proves it works?
what risk remains?
who approved it?
can the whole agent run be replayed, compared, or reverted?
```

The winning model is not "Git with AI labels." It is Git plus provenance,
execution history, review evidence, agent identity, and replayable intent.

## Product Direction

Threadline should make the primary unit of history an `AgentRun`, not a file.

```text
AgentRun
- id
- goal / user request
- agent: Codex, Claude, Cursor, Copilot, etc.
- model
- cwd / repo
- base git ref
- current git ref / dirty state
- started_at / ended_at
- status: running, awaiting, failed, verified, accepted
- files changed
- tool calls
- commands run
- tests run
- runtime checks
- evidence
- human approvals
- risk flags
```

The UI should answer:

```text
What was the agent trying to do?
What did it change?
What evidence proves it worked?
What is still risky?
Can I trust, replay, compare, or revert it?
```

## UI Shape

The selected folder/session detail should become an agent-run page.

```text
threadline
Goal: Make Threadline a normal minimizable macOS app
Agent: Codex
Status: Verified / Needs Review

Timeline
1. User requested normal app behavior.
2. Agent changed NSPanel -> NSWindow.
3. Agent installed/restarted app.
4. User reported minimize still broken.
5. Agent added .miniaturizable.
6. Agent fixed session flapping.
7. Agent added Codex apply_patch provenance.
8. Tests passed.
9. Running app verified.

Evidence
- swift test passed
- installed binary running pid=...
- AXMinimized=true verified
- session list stable across refreshes

Files Edited By This Agent Run
- Panel.swift
- LiveAgents.swift
- ProcTable.swift
- CodexSource.swift
- docs / tests / installer

Risk
- No explicit app version/build ID yet
- Installed binary hash differs after ad-hoc signing
- Human review pending
```

## Concrete Features

1. Rename or clarify the current file section:

```text
Files Edited
```

should become:

```text
Files Edited By This Session
```

or:

```text
Files Edited By This Agent Run
```

These rows are provenance/edit attribution, not app versions.

2. Add a run summary card:

```text
Goal
"Make Threadline work like a normal minimizable macOS app"

Outcome
Implemented, tested, installed, verified running.

Trust
Tests: passed
Runtime check: passed
Human review: pending
Risk: medium
```

3. Add an Evidence tab:

```text
swift test                     passed
./install.sh                   passed
threadline-overlay status      pid=55918 agents=17
AXMinimized check              true
session stability sample       stable
```

4. Add an intent timeline:

```text
10:01 User: make app not fixed at top
10:25 User: cannot minimize
10:34 User: sessions are flapping
10:43 User: why only SessionModel?
10:46 Agent: added Codex apply_patch parsing
```

5. Add build/version metadata to the overlay binary:

```text
threadline-overlay version
- version: 0.1.0
- git_sha: dirty-abc123
- built_at: 2026-05-16T22:46
- installed_at: 2026-05-16T22:47
- binary_sha256: ...
```

`status` should also include enough build identity to prove which code is
actually running.

6. Add trust/status badges:

```text
RUNNING
CHANGED
TESTED
INSTALLED
VERIFIED
NEEDS REVIEW
ACCEPTED
```

7. Eventually support run-level rollback:

```text
Revert all edits from this run
```

This requires preserving patches/tool calls grouped by agent run.

## Developer Expectations

Developers in the agentic age want control and trust more than raw speed.
The versioning layer should support questions like:

```text
Show me the diff.
Show me why the diff exists.
Show me who or what made it.
Show me what the agent saw.
Show me what it tried and rejected.
Show me which tests prove it.
Show me what changed after review.
Let me revert the whole agent run.
Let me trust it without rereading every token.
```

## Implementation Notes From This Session

The current app has already moved in this direction:

- The overlay now behaves as a normal macOS app window instead of a top-pinned
  floating panel.
- The window supports real minimization via `.miniaturizable`.
- The session flapping bug was reduced by filtering Threadline's own
  non-interactive summarizer helpers (`claude -p`, `codex exec`) out of live
  agent discovery.
- Codex `apply_patch` events are now parsed into `filesEdited`, `fileChanges`,
  line counts, tool counts, and patch snippets.

Remaining gaps:

- The overlay still has no explicit build/version command.
- `Files Edited` is not a version list; the UI should label it as session/run
  provenance.
- Tests and runtime checks are not yet first-class evidence rows.
- Human approval/review state is not modeled.
- Agent runs are inferred from sessions rather than explicit first-class
  records.

## North Star

Threadline should become the agentic version ledger.

Git tells you what changed.
Threadline tells you why, by whom, with what proof, and whether you should
trust it.
