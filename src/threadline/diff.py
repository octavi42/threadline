from __future__ import annotations

import difflib
import hashlib
from typing import Any

from . import history


def short_id(session_id: str) -> str:
    return hashlib.sha256(session_id.encode("utf-8")).hexdigest()[:7]


def resolve(prefix: str) -> str | None:
    """Resolve a short id, full id, or substring to a full session id."""
    if not prefix:
        return None
    entries = history.read_index()
    full_ids = [e["id"] for e in entries if e.get("id")]

    if prefix in full_ids:
        return prefix

    matches = [sid for sid in full_ids if short_id(sid).startswith(prefix)]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        return None

    matches = [sid for sid in full_ids if prefix in sid]
    if len(matches) == 1:
        return matches[0]
    return None


def _files_at(session: dict[str, Any], snapshot_index: int) -> dict[str, str]:
    snaps = session.get("snapshots") or []
    if not snaps:
        return {}
    snapshot_index = max(-len(snaps), min(snapshot_index, len(snaps) - 1))
    return dict(snaps[snapshot_index].get("files") or {})


def _text_for(blob_sha: str | None) -> list[str] | None:
    if blob_sha is None:
        return None
    data = history.read_blob(blob_sha)
    if data is None:
        return None
    if b"\x00" in data[:8192]:
        return None
    return data.decode("utf-8", errors="replace").splitlines(keepends=True)


def _diff_files(
    label_a: str,
    files_a: dict[str, str],
    label_b: str,
    files_b: dict[str, str],
) -> str:
    paths = sorted(set(files_a) | set(files_b))
    out: list[str] = []
    for rel in paths:
        sha_a = files_a.get(rel)
        sha_b = files_b.get(rel)
        if sha_a == sha_b:
            continue
        text_a = _text_for(sha_a) or []
        text_b = _text_for(sha_b) or []
        if not text_a and not text_b:
            out.append(f"# binary or unreadable: {rel}\n")
            continue
        diff = difflib.unified_diff(
            text_a,
            text_b,
            fromfile=f"{label_a}:{rel}",
            tofile=f"{label_b}:{rel}",
            lineterm="",
        )
        chunk = list(diff)
        if chunk:
            out.append("\n".join(chunk) + "\n")
    return "".join(out)


def diff_one(session_id: str) -> str:
    session = history.read_session(session_id)
    if session is None:
        return f"# no session: {session_id}\n"
    snaps = session.get("snapshots") or []
    if not snaps:
        return f"# session has no snapshots yet: {short_id(session_id)}\n"
    files_first = _files_at(session, 0)
    files_last = _files_at(session, -1)
    if files_first == files_last and len(snaps) == 1:
        return f"# only one snapshot recorded; no within-session diff available: {short_id(session_id)}\n"
    return _diff_files("start", files_first, "end", files_last)


def diff_two(a_id: str, b_id: str) -> str:
    sa = history.read_session(a_id)
    sb = history.read_session(b_id)
    if sa is None or sb is None:
        return f"# session not found: {a_id if sa is None else b_id}\n"
    snaps_a = sa.get("snapshots") or []
    snaps_b = sb.get("snapshots") or []
    if not snaps_a or not snaps_b:
        return "# one or both sessions have no snapshots\n"
    files_a = _files_at(sa, -1)
    files_b = _files_at(sb, -1)
    label_a = f"{sa.get('agent')}:{short_id(a_id)}"
    label_b = f"{sb.get('agent')}:{short_id(b_id)}"
    header = ""
    base_a = sa.get("base_commit")
    base_b = sb.get("base_commit")
    if base_a and base_b and base_a != base_b:
        header = (
            f"# warning: different base commits\n"
            f"#   {label_a} base={base_a}\n"
            f"#   {label_b} base={base_b}\n"
            f"# diffing intersection only.\n\n"
        )
    return header + _diff_files(label_a, files_a, label_b, files_b)
