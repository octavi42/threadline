# Threadline V1 Direction

Threadline needs to be simplified hard.

Threadline should not be positioned as:

- another AI coding assistant
- another agent dashboard
- another chat UI
- another IDE
- a generic mission control app

## Core Thesis

Threadline is the layer between AI coding sessions and pull requests.

Its job is to answer one question:

```text
Can I trust this AI work enough to review, continue, or turn it into a PR?
```

The product should turn messy AI coding activity from Claude Code, Codex,
Cursor, terminal, and Git into a clear pre-PR trust state.

The fundamental user need:

```text
Developers are running multiple AI coding sessions and losing track of what is
done, stuck, risky, waiting for approval, or safe to review.
```

V1 should be extremely obvious. The user should open Threadline and instantly
understand:

```text
This tells me what my AI coding agents are doing and which ones need me.
```

The first version should feel like an AI work inbox or notification center for
coding agents.

## V1 User-Facing Model

Each session or work item should be a simple card or row:

```text
Claude - Needs you
Waiting for approval to run tests
Action: Jump back / approve

Codex - Risky
Changed 5 files, no tests run
Action: Run tests before review

Cursor - Ready to review
Changed 2 files, tests passed
Action: Review diff

Claude - Stuck
Same error repeated 4 times
Action: Jump back / fix prompt
```

Do not expose many complex categories at first.

Reduce the user-facing status model to:

- Ready to review
- Risky / unverified
- Needs you
- Tests failed
- Stuck
- Still working

Everything else is evidence behind the status.

## Internal Signals

Threadline can track:

- agent/tool
- project/repo
- branch
- dirty files
- changed files
- lines added/removed
- prompt/goal
- commands run
- tests run
- test pass/fail
- errors/retries
- approval waiting state
- context/cost if available

Externally, Threadline should answer only:

1. What needs my attention now?
2. What changed?
3. Did tests run?
4. Is it risky or ready?
5. What should I do next?
6. Can I jump back to the right terminal/editor?

## First Screen

The first product screen should look conceptually like:

```text
Project: threadline

Claude   Needs you    wants approval to run tests
Codex    Ready        3 files changed - tests passed
Cursor   Risky        5 files changed - no tests run
Claude   Stuck        same error repeated 4x
Git      Unverified   6 dirty files - unknown evidence
```

Selecting a row opens:

```text
Goal:
Fix login redirect bug

Changed:
auth.ts, middleware.ts

Evidence:
No tests run

Risk:
Touched auth flow

Next action:
Run auth tests before review

Jump back:
Enter
```

## Product Promise

Main v1 promise:

```text
Know which AI coding sessions are ready, risky, stuck, or waiting for you.
```

The deeper long-term thesis is:

```text
Pre-PR trust layer for AI-generated code.
```

But that is too abstract for v1 marketing. The obvious user-facing hook is:

```text
I lost track of my Claude/Codex/Cursor sessions. Threadline tells me which one
needs me and whether the work is safe to review.
```

## Do Not Start With

Avoid overbuilding scoring systems early.

Do not start with:

- trust score
- evidence index
- productivity analytics
- team surveillance
- manager dashboard
- full PR automation
- GitHub replacement
- agent orchestration

Start with simple, human-readable labels and next actions.

Threadline should not help developers create more AI work. It should help them
trust, review, and act on the AI work they already created.

## MVP Scope

1. Agent Inbox

A ranked list of active/recent AI coding sessions grouped by project.

2. Actionable Status

Each session has one clear state:

```text
Ready, Risky, Needs you, Tests failed, Stuck, Working.
```

3. Reason

One short explanation:

```text
No tests run
Tests passed
Waiting for approval
Same error repeated
Changed auth files
```

4. Next Action

One obvious action:

```text
Review diff
Run tests
Approve
Jump back
Continue
Ignore
```

5. Jump Back

Press Enter or click to return to the exact terminal/editor/session.

6. Diff Digest

Show changed files, branch, dirty count, and test evidence.

## Design Principle

```text
Messy AI session -> clear trust state -> next human action.
```

That is Threadline v1.
