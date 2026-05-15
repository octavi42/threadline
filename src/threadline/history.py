from __future__ import annotations

import hashlib
import json
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .cache import STATE_DIR

SNAPSHOTS_DIR = STATE_DIR / "snapshots"
OBJECTS_DIR = SNAPSHOTS_DIR / "objects"
SESSIONS_HISTORY_DIR = SNAPSHOTS_DIR / "sessions"
INDEX_PATH = SNAPSHOTS_DIR / "index.json"
TAIL_STATE_PATH = SNAPSHOTS_DIR / "tail-state.json"

MAX_FILE_BYTES = 1_000_000


def ensure_history_dirs() -> None:
    OBJECTS_DIR.mkdir(parents=True, exist_ok=True)
    SESSIONS_HISTORY_DIR.mkdir(parents=True, exist_ok=True)


def session_id_for(agent: str, jsonl_path: str) -> str:
    return f"{agent}:{jsonl_path}"


def _session_filename(session_id: str) -> Path:
    digest = hashlib.sha256(session_id.encode("utf-8")).hexdigest()
    return SESSIONS_HISTORY_DIR / f"{digest}.json"


def store_blob(data: bytes) -> str:
    sha = hashlib.sha256(data).hexdigest()
    path = OBJECTS_DIR / sha[:2] / sha[2:]
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_bytes(data)
        tmp.rename(path)
    return sha


def read_blob(sha: str) -> bytes | None:
    path = OBJECTS_DIR / sha[:2] / sha[2:]
    if not path.exists():
        return None
    return path.read_bytes()


def read_session(session_id: str) -> dict[str, Any] | None:
    path = _session_filename(session_id)
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None


def write_session(session_id: str, data: dict[str, Any]) -> None:
    ensure_history_dirs()
    path = _session_filename(session_id)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(
        json.dumps(data, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    tmp.rename(path)


def read_index() -> list[dict[str, Any]]:
    if not INDEX_PATH.exists():
        return []
    try:
        data = json.loads(INDEX_PATH.read_text(encoding="utf-8"))
        return data if isinstance(data, list) else []
    except json.JSONDecodeError:
        return []


def write_index(entries: list[dict[str, Any]]) -> None:
    ensure_history_dirs()
    tmp = INDEX_PATH.with_suffix(".tmp")
    tmp.write_text(
        json.dumps(entries, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    tmp.rename(INDEX_PATH)


def update_index_entry(entry: dict[str, Any]) -> None:
    entries = read_index()
    sid = entry["id"]
    replaced = False
    for i, existing in enumerate(entries):
        if existing.get("id") == sid:
            entries[i] = entry
            replaced = True
            break
    if not replaced:
        entries.append(entry)
    entries.sort(key=lambda e: e.get("updated_at", ""), reverse=True)
    write_index(entries)


def _entry_from_session(session: dict[str, Any]) -> dict[str, Any]:
    snaps = session.get("snapshots") or []
    return {
        "id": session.get("id"),
        "agent": session.get("agent"),
        "cwd": session.get("cwd"),
        "first_prompt": session.get("first_prompt"),
        "started_at": session.get("started_at"),
        "updated_at": session.get("updated_at"),
        "base_commit": session.get("base_commit"),
        "base_branch": session.get("base_branch"),
        "file_count": len(snaps[-1]["files"]) if snaps else 0,
        "snapshot_count": len(snaps),
        "cwd_not_git": session.get("cwd_not_git"),
    }


def rebuild_index() -> int:
    """Rebuild index.json from session files. Cheaper than per-entry updates
    when many sessions are touched in one pass."""
    ensure_history_dirs()
    entries: list[dict[str, Any]] = []
    for path in SESSIONS_HISTORY_DIR.glob("*.json"):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(data, dict) and data.get("id"):
            entries.append(_entry_from_session(data))
    entries.sort(key=lambda e: e.get("updated_at") or "", reverse=True)
    write_index(entries)
    return len(entries)


def _git(cwd: str, args: list[str]) -> str | None:
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=cwd,
            text=True,
            capture_output=True,
            check=False,
            timeout=5,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def git_ls_files(cwd: str) -> list[str] | None:
    out = _git(cwd, ["ls-files", "-z"])
    if out is None:
        return None
    return [p for p in out.split("\0") if p]


def git_head_commit(cwd: str) -> str | None:
    return _git(cwd, ["rev-parse", "HEAD"])


def git_current_branch(cwd: str) -> str | None:
    return _git(cwd, ["rev-parse", "--abbrev-ref", "HEAD"])


@dataclass
class SnapshotResult:
    changed: bool
    file_count: int
    reason: str = ""


def register_session(
    session_id: str,
    *,
    agent: str,
    cwd: str | None,
    jsonl_path: str,
    first_prompt: str | None,
    now_iso: str,
) -> None:
    """Record session metadata without snapshotting files. Used on first
    encounter so the index can list historical sessions without a heavy
    backfill of every project's tracked files."""
    ensure_history_dirs()
    session = read_session(session_id)
    if session is None:
        session = {
            "id": session_id,
            "agent": agent,
            "cwd": cwd,
            "jsonl_path": jsonl_path,
            "first_prompt": first_prompt,
            "started_at": now_iso,
            "base_commit": None,
            "base_branch": None,
            "snapshots": [],
        }
    if first_prompt and not session.get("first_prompt"):
        session["first_prompt"] = first_prompt
    if cwd and not session.get("cwd"):
        session["cwd"] = cwd
    session["updated_at"] = now_iso
    write_session(session_id, session)


def _read_file_for_snapshot(path: Path) -> bytes | None:
    try:
        if path.stat().st_size > MAX_FILE_BYTES:
            return None
        data = path.read_bytes()
    except OSError:
        return None
    if b"\x00" in data[:8192]:
        return None
    return data


def snapshot_session(
    session_id: str,
    *,
    agent: str,
    cwd: str | None,
    jsonl_path: str,
    first_prompt: str | None,
    now_iso: str,
) -> SnapshotResult:
    ensure_history_dirs()

    if not cwd or not Path(cwd).is_dir():
        return SnapshotResult(changed=False, file_count=0, reason="no_cwd")

    tracked = git_ls_files(cwd)
    if tracked is None:
        session = read_session(session_id) or {
            "id": session_id,
            "agent": agent,
            "cwd": cwd,
            "jsonl_path": jsonl_path,
            "first_prompt": first_prompt,
            "started_at": now_iso,
            "cwd_not_git": True,
            "snapshots": [],
        }
        session["updated_at"] = now_iso
        if first_prompt and not session.get("first_prompt"):
            session["first_prompt"] = first_prompt
        write_session(session_id, session)
        update_index_entry({
            "id": session_id,
            "agent": agent,
            "cwd": cwd,
            "first_prompt": session.get("first_prompt"),
            "started_at": session.get("started_at"),
            "updated_at": now_iso,
            "file_count": 0,
            "cwd_not_git": True,
        })
        return SnapshotResult(changed=False, file_count=0, reason="not_git")

    files: dict[str, str] = {}
    for rel in tracked:
        full = Path(cwd) / rel
        data = _read_file_for_snapshot(full)
        if data is None:
            continue
        files[rel] = store_blob(data)

    session = read_session(session_id)
    if session is None:
        session = {
            "id": session_id,
            "agent": agent,
            "cwd": cwd,
            "jsonl_path": jsonl_path,
            "first_prompt": first_prompt,
            "started_at": now_iso,
            "base_commit": git_head_commit(cwd),
            "base_branch": git_current_branch(cwd),
            "snapshots": [],
        }

    last_files = session["snapshots"][-1]["files"] if session["snapshots"] else None
    if last_files == files:
        session["updated_at"] = now_iso
        write_session(session_id, session)
        return SnapshotResult(changed=False, file_count=len(files), reason="no_change")

    session["snapshots"].append({"at": now_iso, "files": files})
    session["updated_at"] = now_iso
    if first_prompt and not session.get("first_prompt"):
        session["first_prompt"] = first_prompt
    write_session(session_id, session)
    return SnapshotResult(changed=True, file_count=len(files))


def read_tail_state() -> dict[str, dict[str, Any]]:
    if not TAIL_STATE_PATH.exists():
        return {}
    try:
        data = json.loads(TAIL_STATE_PATH.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except json.JSONDecodeError:
        return {}


def write_tail_state(state: dict[str, dict[str, Any]]) -> None:
    ensure_history_dirs()
    tmp = TAIL_STATE_PATH.with_suffix(".tmp")
    tmp.write_text(
        json.dumps(state, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    tmp.rename(TAIL_STATE_PATH)
