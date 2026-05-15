"""Structured JSON output for downstream consumers (Swift overlay, web UI, etc.).

The schema is the public contract between the Python core and any renderer.
Keep it stable; add fields, don't rename them.
"""
from __future__ import annotations

import json
from datetime import datetime
from typing import Any

from .evidence import HunkEvidence


def _test_to_dict(call) -> dict[str, Any]:
    cmd = ""
    if isinstance(call.input, dict):
        cmd = str(call.input.get("command") or call.input.get("cmd") or "")
    return {
        "tool": call.tool,
        "command": cmd,
        "output": call.output or "",
        "exit_status": call.exit_status,
        "timestamp": call.timestamp,
    }


def report_dict(
    evidence: list[HunkEvidence],
    *,
    repo: str | None = None,
    base: str | None = None,
    session: str | None = None,
) -> dict[str, Any]:
    """Build the JSON-serializable report dict."""
    by_file: dict[str, list[HunkEvidence]] = {}
    for e in evidence:
        by_file.setdefault(e.attribution.hunk.file_path, []).append(e)

    files = []
    for file_path, hunks in by_file.items():
        # File-level rollup: union the prompts + edit counts across hunks (they're
        # the same per file with current attribution, but normalize defensively).
        all_framing: dict[str, dict] = {}
        all_immediate: dict[str, dict] = {}
        edit_counts: dict[str, int] = {}
        total_retries = 0
        any_failure = False
        for e in hunks:
            for p in e.attribution.framing_prompts:
                all_framing.setdefault(p.id, {"source": p.source, "text": p.text})
            for p in e.attribution.prompts:
                all_immediate.setdefault(p.id, {"source": p.source, "text": p.text})
            for ev in e.attribution.edits:
                edit_counts[ev.tool] = edit_counts.get(ev.tool, 0) + 1
            total_retries = max(total_retries, e.retry_count)
            any_failure = any_failure or e.has_test_failure

        hunk_dicts = []
        for e in hunks:
            h = e.attribution.hunk
            hunk_dicts.append({
                "base_start": h.base_start,
                "base_count": h.base_count,
                "new_start": h.new_start,
                "new_count": h.new_count,
                "tests": [_test_to_dict(t) for t in e.test_runs],
            })

        files.append({
            "path": file_path,
            "framing_prompts": list(all_framing.values()),
            "immediate_prompts": list(all_immediate.values()),
            "edit_counts": [
                {"tool": tool, "count": n} for tool, n in edit_counts.items()
            ],
            "retry_count": total_retries,
            "has_test_failure": any_failure,
            "hunks": hunk_dicts,
        })

    return {
        "schema_version": 1,
        "repo": repo,
        "base": base or "HEAD",
        "session": session,
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "files": files,
    }


def render_json(
    evidence: list[HunkEvidence],
    *,
    repo: str | None = None,
    base: str | None = None,
    session: str | None = None,
) -> str:
    return json.dumps(
        report_dict(evidence, repo=repo, base=base, session=session),
        indent=2,
    )
