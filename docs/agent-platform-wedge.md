# Threadline Agent Platform Wedge

Date: 2026-05-14

## Context

The goal discussed was not to build a direct GitHub clone. GitHub already owns code hosting, pull requests, issues, CI, package registries, permissions, and enterprise workflows. Rebuilding all of that first would be too broad.

The more credible path is to build the layer GitHub is moving toward but cannot fully own: agent-native software work orchestration across local terminals, Claude Code, Codex, Cursor, Git, branches, issues, reviews, and session history.

## Market Pains

AI coding agents can now create branches, open PRs, and review code inside tools like GitHub, Codex, and Claude Code. That makes PR creation and AI review table stakes rather than a defensible wedge.

The sharper pain is before a PR exists:

- Developers run multiple agents across repos and terminals.
- Agent sessions become hard to observe once they involve many tool calls.
- Reviewers need proof that generated code was tested and understood.
- AI-generated PRs can look plausible while hiding subtle logic issues.
- Maintainers are overloaded by low-quality or poorly explained AI changes.
- GitHub sees the final artifact, but not the messy local work that produced it.
- Each agent sees only its own session, not the full cross-tool work surface.

## Actual Wedge

Threadline should be the neutral, local-first control plane for multi-agent software work before it becomes a PR.

Short positioning:

> Threadline is the inbox and flight recorder for AI coding agents.

Commercial positioning:

> Threadline helps engineering teams supervise, compare, and verify AI coding work across Codex, Claude, Cursor, and GitHub before it enters the review queue.

## Why Threadline

Threadline already has the right raw materials:

- local terminal/session capture
- Claude/Codex/Cursor session parsing
- per-folder grouping
- git branch and dirty-state awareness
- files touched
- task state
- tool usage
- summaries
- local-first operation

This makes Threadline closer to an AI engineering cockpit than a GitHub replacement.

## First Killer Feature

Build an Agent Inbox.

Example:

```text
Repo: payments-api

Codex      running   touched auth.py, billing.py   tests not run
Claude     done      touched billing.py only        tests passed
Cursor     stuck     same error 4 times             needs input
```

Each row should open a timeline:

- original prompt
- current task
- files changed
- commands run
- tests passed or failed
- repeated errors or stuck loops
- summary of what changed
- risk notes
- suggested next human action
- promote to branch or draft PR

## Product Direction

Do first:

- persistent session version history
- local agent timeline
- changed-file and risk summary
- compare two agents working on the same repo or issue
- GitHub issue/PR linking
- draft PR preparation from session evidence
- searchable local work history

Avoid early:

- building Git hosting
- replacing GitHub issues
- building CI infrastructure
- package registry
- enterprise permissions
- full code review replacement

## Strategic Bet

GitHub owns the repo graph.

Threadline can own agent accountability: what happened, why it happened, what evidence exists, and whether the work is ready to enter the review queue.

