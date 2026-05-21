# Contributing to Threadline

Thanks for taking the time to improve Threadline.

## Development Setup

Threadline is currently a macOS Swift app in `overlay/`.

Requirements:

- macOS 13 or later
- Xcode 14 or later, or Swift 5.9 command-line tools

Build and test:

```bash
cd overlay
swift build
swift test
```

Live Cursor E2E (macOS with running `cursor-agent` processes):

```bash
cd overlay
THREADLINE_BIN="$(pwd)/.build/release/threadline-overlay" ./scripts/e2e-live.sh
```

Optional in-process live tests:

```bash
THREADLINE_LIVE_TEST=1 swift test --filter LiveConsistency
```

Run from source:

```bash
cd overlay
swift run threadline-overlay show
```

## Pull Requests

Before opening a pull request:

- Keep the change focused and describe the user-visible behavior.
- Add or update tests when changing parsing, session grouping, status logic, or installer behavior.
- Run `swift test` from `overlay/`.
- Avoid committing local session data, logs, build output, or secrets.

## Reporting Bugs

When reporting a bug, include:

- macOS version and Mac architecture.
- Threadline version or commit.
- Agent source involved: Claude Code, Codex CLI, Cursor, or shell hook.
- Steps to reproduce and expected behavior.
- Relevant logs with private paths, prompts, and secrets redacted.

## Privacy Notes

Threadline reads local agent session files to show local context. Do not paste full private transcripts into public issues unless you have reviewed and redacted them.
