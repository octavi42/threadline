"""`threadline xray` subcommand: end-to-end demo path.

Flow:
1. Discover repo root via ``git rev-parse --show-toplevel``.
2. Read git diff for the requested ref (dirty tree by default).
3. Locate the relevant session JSONL — explicit ``--session`` or auto-detect
   the newest Claude project file matching the current cwd.
4. Parse session -> events; parse diff -> hunks; attribute; assemble evidence.
5. Render a human report to stdout.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from .events import Event, parse
from .evidence import HunkEvidence, assemble
from .mapper import attribute, parse_diff


def _git(args: list[str], cwd: Path) -> tuple[int, str]:
    res = subprocess.run(
        ["git", *args], cwd=str(cwd), text=True, capture_output=True, check=False
    )
    return res.returncode, (res.stdout if res.returncode == 0 else res.stderr)


def _repo_root(start: Path) -> Path | None:
    code, out = _git(["rev-parse", "--show-toplevel"], start)
    return Path(out.strip()) if code == 0 and out.strip() else None


def _diff_text(repo: Path, base: str | None) -> str:
    args = ["diff", "--no-color", "--unified=0"]
    if base:
        args.append(base)
    code, out = _git(args, repo)
    return out if code == 0 else ""


def _slugify_cwd(cwd: Path) -> str:
    """Claude encodes project dirs as the absolute POSIX path with `/` -> `-`."""
    return str(cwd).replace("/", "-")


def _autodetect_session(repo: Path) -> Path | None:
    """Find the newest Claude JSONL for this repo. Codex auto-detect is TBD."""
    projects = Path.home() / ".claude" / "projects"
    if not projects.is_dir():
        return None
    slug = _slugify_cwd(repo)
    candidate_dir = projects / slug
    if not candidate_dir.is_dir():
        return None
    jsonls = list(candidate_dir.glob("*.jsonl"))
    if not jsonls:
        return None
    return max(jsonls, key=lambda p: p.stat().st_mtime)


def _truncate(text: str, n: int = 200) -> str:
    text = text.replace("\n", " ").strip()
    return text if len(text) <= n else text[: n - 1] + "…"


def render(evidence: list[HunkEvidence]) -> str:
    if not evidence:
        return "threadline xray: no overlap between the diff and the session.\n"

    lines: list[str] = []
    by_file: dict[str, list[HunkEvidence]] = {}
    for e in evidence:
        by_file.setdefault(e.attribution.hunk.file_path, []).append(e)

    for file_path, hunks in by_file.items():
        lines.append(f"── {file_path} ──")
        for e in hunks:
            h = e.attribution.hunk
            range_str = f"@@ +{h.new_start},{h.new_count} -{h.base_start},{h.base_count}"
            lines.append(f"  {range_str}")
            display_prompts = e.attribution.framing_prompts or e.attribution.prompts
            if display_prompts:
                framing_ids = {p.id for p in e.attribution.framing_prompts}
                immediate_ids = {p.id for p in e.attribution.prompts}
                for p in display_prompts:
                    label = "prompt" if p.id in framing_ids and p.id not in immediate_ids else "prompt"
                    lines.append(f"    {label} ({p.source}): {_truncate(p.text)}")
            else:
                lines.append("    prompt: <none in session>")
            if e.attribution.edits:
                tool_counts: dict[str, int] = {}
                for ev in e.attribution.edits:
                    tool_counts[ev.tool] = tool_counts.get(ev.tool, 0) + 1
                summary = ", ".join(f"{n}× {t}" for t, n in tool_counts.items())
                retry_note = f"   (retries: {e.retry_count})" if e.retry_count else ""
                lines.append(f"    edits: {summary}{retry_note}")
            else:
                lines.append("    edits: <none>")
            for t in e.test_runs:
                if t.exit_status == 0:
                    status = "✓"
                elif t.exit_status == -1:
                    status = "⚠ interrupted"
                elif t.exit_status is not None:
                    status = f"✗ exit {t.exit_status}"
                else:
                    status = "·"
                cmd = ""
                if isinstance(t.input, dict):
                    cmd = str(t.input.get("command") or t.input.get("cmd") or "")
                out_preview = _truncate(t.output or "", 80) if t.output else ""
                lines.append(f"    test:  {status}  {_truncate(cmd, 60)}  → {out_preview}")
            if not e.test_runs:
                lines.append("    test:  <no test run found in this prompt>")
        lines.append("")

    return "\n".join(lines)


def xray_command(base: str | None = None, session: str | None = None) -> int:
    cwd = Path(os.getcwd()).resolve()
    repo = _repo_root(cwd)
    if repo is None:
        print("threadline xray: not inside a git repo.", file=sys.stderr)
        return 2

    diff_text = _diff_text(repo, base)
    if not diff_text.strip():
        ref_label = base or "HEAD"
        print(f"threadline xray: no changes vs {ref_label}.", file=sys.stderr)
        return 0

    if session:
        session_path = Path(session).expanduser()
    else:
        session_path = _autodetect_session(repo)
    if session_path is None or not session_path.is_file():
        print(
            "threadline xray: no session JSONL found. "
            "Pass --session <path> to point at a Claude or Codex JSONL.",
            file=sys.stderr,
        )
        return 2

    events: list[Event] = parse(session_path)
    hunks = parse_diff(diff_text)
    attrs = attribute(events, hunks, repo_root=str(repo))
    evidence = assemble(events, attrs)
    sys.stdout.write(render(evidence))
    return 0
