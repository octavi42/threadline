from __future__ import annotations

from datetime import datetime

from .collect import Context


NOISE_PREFIXES = (
    "warning:",
    "hint:",
    "/users/",
)


def meaningful_tail(text: str, limit: int = 8) -> list[str]:
    lines = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.lower().startswith(NOISE_PREFIXES):
            continue
        lines.append(line)
    return lines[-limit:]


def changed_files(git_status: str, limit: int = 8) -> list[str]:
    files = []
    for line in git_status.splitlines():
        parts = line.strip().split(maxsplit=1)
        if len(parts) == 2:
            files.append(parts[1])
    return files[:limit]


def next_action(context: Context, files: list[str]) -> str:
    tail = "\n".join(meaningful_tail(context.pane_text, limit=12)).lower()

    if "pytest" in tail and ("failed" in tail or "error" in tail):
        return "Inspect the failing test output and patch the related file."
    if "traceback" in tail or "exception" in tail:
        return "Fix the visible exception, then rerun the command."
    if files:
        return "Review the changed files, then run the smallest relevant test."
    if context.git_branch:
        return "Make a focused change on this branch or run the next verification command."
    return "Open the target repo in tmux so Threadline can infer the active task."


def render_summary(context: Context) -> str:
    files = changed_files(context.git_status)
    tail = meaningful_tail(context.pane_text)
    branch = context.git_branch or "none"
    changed = ", ".join(files) if files else "none"
    activity = tail[-1] if tail else "no captured pane activity"
    generated = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    lines = [
        f"Current task: working in {context.cwd}",
        f"Git: branch {branch}; changed files: {changed}",
        f"Recent activity: {activity}",
        f"Next action: {next_action(context, files)}",
        f"Updated: {generated}",
    ]

    if context.warnings:
        lines.append(f"Note: {'; '.join(context.warnings)}")

    return "\n".join(lines)

