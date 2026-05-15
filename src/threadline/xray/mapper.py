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

# Short replies that authorize/redirect but don't frame work. When an edit's
# immediate prompt is one of these, we walk backward in the session to find the
# nearest substantive prompt — that's the one the reviewer wants to see.
_STOPWORD_PROMPTS: frozenset[str] = frozenset({
    "yes", "yes please", "y", "yep", "yeah", "yup",
    "no", "nope", "n",
    "ok", "okay", "k", "kk", "sure", "fine",
    "do it", "do this", "go", "go ahead", "let's go", "lets go",
    "continue", "keep going", "proceed", "next", "next one", "next step",
    "thanks", "thank you", "thx", "ty", "please",
    "stop", "pause", "wait", "hold on",
})


def _is_substantive(text: str) -> bool:
    """A prompt is substantive if it frames work — not a bare authorization."""
    cleaned = text.strip().lower().rstrip(".!?")
    if not cleaned:
        return False
    if cleaned in _STOPWORD_PROMPTS:
        return False
    # Anything beyond ~10 chars that isn't a stopword likely carries intent.
    return len(cleaned) > 10


@dataclass(frozen=True)
class Hunk:
    file_path: str           # repo-relative path on the new side
    base_start: int          # 1-based start line in the base ref (0 if pure addition)
    base_count: int
    new_start: int           # 1-based start line in the new file
    new_count: int
    body: tuple[str, ...] = ()  # raw +/-/space lines following the @@ header


@dataclass
class HunkAttribution:
    hunk: Hunk
    edits: list[ToolCall] = field(default_factory=list)
    prompts: list[Prompt] = field(default_factory=list)         # immediate (rolling) prompts
    framing_prompts: list[Prompt] = field(default_factory=list) # nearest substantive predecessors


_DIFF_HEADER_NEW = re.compile(r"^\+\+\+ b/(.+)$")
_DIFF_HEADER_DEL = re.compile(r"^--- a/(.+)$")
_HUNK_HEADER = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def parse_diff(diff_text: str) -> dict[str, list[Hunk]]:
    """Parse `git diff --unified=N` text into a mapping of file -> hunks.

    Captures both the @@ headers (line ranges) and the body lines (the
    `+`/`-`/` ` content that follows). The body lets renderers display the
    actual change inline instead of only metadata.
    """
    hunks: dict[str, list[Hunk]] = {}
    current_file: str | None = None
    current_body: list[str] = []
    pending: list[tuple[str, dict]] = []  # (file_path, header_kwargs)

    def flush_pending_with_body():
        if pending:
            file_path, kwargs = pending.pop()
            hunks[file_path].append(
                Hunk(file_path=file_path, body=tuple(current_body), **kwargs)
            )
            current_body.clear()

    for line in diff_text.splitlines():
        m = _DIFF_HEADER_NEW.match(line)
        if m:
            flush_pending_with_body()
            current_file = m.group(1)
            hunks.setdefault(current_file, [])
            continue
        if line.startswith("--- ") and _DIFF_HEADER_DEL.match(line):
            flush_pending_with_body()
            current_file = _DIFF_HEADER_DEL.match(line).group(1)
            hunks.setdefault(current_file, [])
            continue
        m = _HUNK_HEADER.match(line)
        if m and current_file is not None:
            flush_pending_with_body()
            pending.append(
                (
                    current_file,
                    {
                        "base_start": int(m.group(1)),
                        "base_count": int(m.group(2)) if m.group(2) is not None else 1,
                        "new_start": int(m.group(3)),
                        "new_count": int(m.group(4)) if m.group(4) is not None else 1,
                    },
                )
            )
            continue
        # Body lines: must follow a hunk header and start with +, -, or space.
        if pending and line[:1] in ("+", "-", " "):
            # Skip the file headers that may appear at the start of bodies
            # (defensive — shouldn't normally happen, but git can emit "\ No
            # newline at end of file" markers which start with backslash).
            current_body.append(line)

    flush_pending_with_body()
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
    chrono_prompts = sorted(prompts_by_id.values(), key=lambda p: p.timestamp)
    idx_by_id = {p.id: i for i, p in enumerate(chrono_prompts)}

    def framing_for(prompt: Prompt) -> Prompt:
        """Walk back through the session for the nearest substantive prompt."""
        if _is_substantive(prompt.text):
            return prompt
        idx = idx_by_id.get(prompt.id)
        if idx is None:
            return prompt
        for i in range(idx - 1, -1, -1):
            cand = chrono_prompts[i]
            if _is_substantive(cand.text):
                return cand
        return prompt

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

        framing: dict[str, Prompt] = {}
        for p in prompt_list:
            f = framing_for(p)
            framing.setdefault(f.id, f)
        framing_list = list(framing.values())

        for h in file_hunks:
            result.append(
                HunkAttribution(
                    hunk=h,
                    edits=edits_sorted,
                    prompts=prompt_list,
                    framing_prompts=framing_list,
                )
            )

    return result
