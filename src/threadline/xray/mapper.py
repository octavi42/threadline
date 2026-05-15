"""Map session events to specific diff hunks.

V1 attribution is file-level: every Edit/Write/apply_patch touching a file is
attributed to every hunk in that file. This is sufficient for the launch demo —
most prompts touch one file at a time, and the originating Prompt is the same
across all hunks in a file anyway. Line-range refinement (via replay-and-anchor
against the prior file state) is a follow-up.

Bash ToolCalls aren't edits, but their outputs become evidence later — the
mapper preserves them in the per-prompt context but doesn't attribute them to
hunks directly.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import PurePath

from .events import Event, Prompt, ToolCall

EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch"}


@dataclass(frozen=True)
class Hunk:
    file_path: str           # repo-relative path on the new side
    base_start: int          # 1-based start line in the base ref (0 if pure addition)
    base_count: int
    new_start: int           # 1-based start line in the new file
    new_count: int


@dataclass
class HunkAttribution:
    hunk: Hunk
    edits: list[ToolCall] = field(default_factory=list)
    prompts: list[Prompt] = field(default_factory=list)


_DIFF_HEADER_NEW = re.compile(r"^\+\+\+ b/(.+)$")
_DIFF_HEADER_DEL = re.compile(r"^--- a/(.+)$")
_HUNK_HEADER = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def parse_diff(diff_text: str) -> dict[str, list[Hunk]]:
    """Parse `git diff --unified=N` text into a mapping of file -> hunks.

    Only the @@ headers are read; hunk bodies are intentionally ignored — line
    counts come from the header, which is what attribution needs.
    """
    hunks: dict[str, list[Hunk]] = {}
    current_file: str | None = None

    for line in diff_text.splitlines():
        m = _DIFF_HEADER_NEW.match(line)
        if m:
            current_file = m.group(1)
            hunks.setdefault(current_file, [])
            continue
        if line.startswith("--- ") and _DIFF_HEADER_DEL.match(line):
            # Track deletion-only files so we can attribute them too.
            current_file = _DIFF_HEADER_DEL.match(line).group(1)
            hunks.setdefault(current_file, [])
            continue
        m = _HUNK_HEADER.match(line)
        if m and current_file is not None:
            base_start = int(m.group(1))
            base_count = int(m.group(2)) if m.group(2) is not None else 1
            new_start = int(m.group(3))
            new_count = int(m.group(4)) if m.group(4) is not None else 1
            hunks[current_file].append(
                Hunk(
                    file_path=current_file,
                    base_start=base_start,
                    base_count=base_count,
                    new_start=new_start,
                    new_count=new_count,
                )
            )

    return hunks


def _normalize(event_path: str | None, repo_root: str | None) -> str | None:
    """Reduce an event's file_path to a repo-relative POSIX path."""
    if not event_path:
        return None
    p = PurePath(event_path)
    if repo_root:
        root = PurePath(repo_root)
        try:
            return p.relative_to(root).as_posix()
        except ValueError:
            pass
    return p.as_posix().lstrip("/")


def attribute(
    events: list[Event],
    diff: dict[str, list[Hunk]],
    repo_root: str | None = None,
) -> list[HunkAttribution]:
    """Attach edit ToolCalls and originating Prompts to each diff hunk."""
    prompts_by_id: dict[str, Prompt] = {
        e.id: e for e in events if isinstance(e, Prompt)
    }

    edits_by_file: dict[str, list[ToolCall]] = {}
    for ev in events:
        if not isinstance(ev, ToolCall):
            continue
        if ev.tool not in EDIT_TOOLS:
            continue
        rel = _normalize(ev.file_path, repo_root)
        if not rel:
            continue
        edits_by_file.setdefault(rel, []).append(ev)
        # Codex apply_patch may have multi-file changes recorded in _patch_changes.
        changes = ev.input.get("_patch_changes") if isinstance(ev.input, dict) else None
        if isinstance(changes, dict):
            for raw_path in changes:
                extra = _normalize(raw_path, repo_root)
                if extra and extra != rel:
                    edits_by_file.setdefault(extra, []).append(ev)

    result: list[HunkAttribution] = []
    for file_path, file_hunks in diff.items():
        edits = edits_by_file.get(file_path, [])
        edits_sorted = sorted(edits, key=lambda c: c.timestamp)
        seen_prompts: dict[str, Prompt] = {}
        for ev in edits_sorted:
            if ev.prompt_id and ev.prompt_id in prompts_by_id and ev.prompt_id not in seen_prompts:
                seen_prompts[ev.prompt_id] = prompts_by_id[ev.prompt_id]
        prompt_list = list(seen_prompts.values())
        for h in file_hunks:
            result.append(
                HunkAttribution(hunk=h, edits=edits_sorted, prompts=prompt_list)
            )

    return result
