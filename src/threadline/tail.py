from __future__ import annotations

import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

from .history import (
    read_tail_state,
    rebuild_index,
    register_session,
    session_id_for,
    snapshot_session,
    write_tail_state,
)

CLAUDE_ROOT = Path.home() / ".claude" / "projects"
CODEX_ROOT = Path.home() / ".codex" / "sessions"
CURSOR_ROOT = (
    Path.home()
    / "Library"
    / "Application Support"
    / "Cursor"
    / "User"
    / "workspaceStorage"
)

DEBOUNCE_SECONDS = 10
POLL_SECONDS = 5
DEFAULT_SCAN_DAYS = 30


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _iter_jsonl(root: Path, since_epoch: float | None = None) -> Iterator[Path]:
    if not root.is_dir():
        return
    for path in root.rglob("*.jsonl"):
        if not path.is_file():
            continue
        if since_epoch is not None:
            try:
                if path.stat().st_mtime < since_epoch:
                    continue
            except OSError:
                continue
        yield path


def _read_new_lines(path: Path, offset: int) -> tuple[list[str], int]:
    try:
        size = path.stat().st_size
    except OSError:
        return [], offset
    if size < offset:
        offset = 0
    if size == offset:
        return [], offset
    try:
        with path.open("rb") as fh:
            fh.seek(offset)
            chunk = fh.read(size - offset)
    except OSError:
        return [], offset
    text = chunk.decode("utf-8", errors="replace")
    lines = text.split("\n")
    if not text.endswith("\n"):
        partial = lines.pop()
        new_offset = size - len(partial.encode("utf-8"))
    else:
        lines.pop()
        new_offset = size
    return [ln for ln in lines if ln.strip()], new_offset


def _parse_claude_record(record: dict[str, Any]) -> dict[str, Any]:
    """Extract cwd + first user prompt candidate from a Claude jsonl record."""
    out: dict[str, Any] = {}
    if cwd := record.get("cwd"):
        out["cwd"] = cwd
    msg = record.get("message") or {}
    if record.get("type") == "user" and msg.get("role") == "user":
        content = msg.get("content")
        text: str | None = None
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    t = block.get("text")
                    if isinstance(t, str) and t.strip() and not t.startswith("<"):
                        text = t
                        break
        if text and not text.startswith("<"):
            out["user_prompt"] = text.strip()
    return out


def _parse_codex_record(record: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    rtype = record.get("type")
    payload = record.get("payload") or {}
    if rtype == "session_meta":
        if cwd := payload.get("cwd"):
            out["cwd"] = cwd
    elif rtype == "event_msg" and payload.get("type") == "user_message":
        msg = payload.get("message")
        if isinstance(msg, str) and msg.strip() and not msg.lstrip().startswith("<"):
            out["user_prompt"] = msg.strip()
    elif rtype == "response_item" and payload.get("type") == "message":
        if payload.get("role") == "user":
            content = payload.get("content") or []
            parts = [
                c.get("text")
                for c in content
                if isinstance(c, dict) and isinstance(c.get("text"), str)
            ]
            text = " ".join(p for p in parts if p)
            stripped = text.strip()
            if stripped and not stripped.startswith("<"):
                out["user_prompt"] = stripped
    return out


def _process_jsonl(
    path: Path,
    agent: str,
    parse_record,
    state: dict[str, dict[str, Any]],
    now: float,
) -> None:
    key = str(path)
    entry = state.get(key) or {}
    first_encounter = "offset" not in entry
    offset = int(entry.get("offset", 0))
    last_snapshot_at = float(entry.get("last_snapshot_at", 0))
    cwd = entry.get("cwd")
    first_prompt = entry.get("first_prompt")

    try:
        mtime = path.stat().st_mtime
    except OSError:
        return

    lines, new_offset = _read_new_lines(path, offset)
    activity = False
    for raw in lines:
        try:
            record = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if not isinstance(record, dict):
            continue
        info = parse_record(record)
        if "cwd" in info and not cwd:
            cwd = info["cwd"]
        if "user_prompt" in info and not first_prompt:
            first_prompt = info["user_prompt"]
        activity = True

    entry.update({
        "offset": new_offset,
        "mtime": mtime,
        "cwd": cwd,
        "first_prompt": first_prompt,
    })
    state[key] = entry

    session_id = session_id_for(agent, str(path))

    # First encounter: register metadata only, do NOT snapshot tracked files.
    # Otherwise the first daemon run would snapshot every historical project
    # the user has ever opened with any agent.
    if first_encounter:
        if cwd is not None:
            register_session(
                session_id,
                agent=agent,
                cwd=cwd,
                jsonl_path=str(path),
                first_prompt=first_prompt,
                now_iso=_now_iso(),
            )
        entry["last_snapshot_at"] = now
        entry["last_result"] = "registered"
        state[key] = entry
        return

    if not activity:
        return
    if cwd is None:
        return
    if now - last_snapshot_at < DEBOUNCE_SECONDS:
        return

    result = snapshot_session(
        session_id,
        agent=agent,
        cwd=cwd,
        jsonl_path=str(path),
        first_prompt=first_prompt,
        now_iso=_now_iso(),
    )
    entry["last_snapshot_at"] = now
    entry["last_result"] = result.reason or ("changed" if result.changed else "no_change")
    state[key] = entry


def _process_cursor(state: dict[str, dict[str, Any]], now: float) -> None:
    if not CURSOR_ROOT.is_dir():
        return
    for workspace in CURSOR_ROOT.iterdir():
        db = workspace / "state.vscdb"
        if not db.is_file():
            continue
        try:
            mtime = db.stat().st_mtime
        except OSError:
            continue
        key = str(db)
        entry = state.get(key) or {}
        first_encounter = "mtime" not in entry
        last_mtime = float(entry.get("mtime", 0))
        last_snapshot_at = float(entry.get("last_snapshot_at", 0))
        cwd = entry.get("cwd") or _read_cursor_workspace_folder(workspace)
        entry["mtime"] = mtime
        entry["cwd"] = cwd
        state[key] = entry

        session_id = session_id_for("cursor", str(workspace))

        if first_encounter:
            if cwd:
                register_session(
                    session_id,
                    agent="cursor",
                    cwd=cwd,
                    jsonl_path=str(db),
                    first_prompt=None,
                    now_iso=_now_iso(),
                )
            entry["last_snapshot_at"] = now
            entry["last_result"] = "registered"
            state[key] = entry
            continue

        if mtime <= last_mtime:
            continue
        if not cwd:
            continue
        if now - last_snapshot_at < DEBOUNCE_SECONDS:
            continue
        result = snapshot_session(
            session_id,
            agent="cursor",
            cwd=cwd,
            jsonl_path=str(db),
            first_prompt=None,
            now_iso=_now_iso(),
        )
        entry["last_snapshot_at"] = now
        entry["last_result"] = result.reason or ("changed" if result.changed else "no_change")
        state[key] = entry


def _read_cursor_workspace_folder(workspace: Path) -> str | None:
    meta = workspace / "workspace.json"
    if not meta.is_file():
        return None
    try:
        data = json.loads(meta.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    folder = data.get("folder")
    if isinstance(folder, str) and folder.startswith("file://"):
        return folder[len("file://"):]
    if isinstance(folder, str):
        return folder
    return None


def run_once(since_days: int | None = DEFAULT_SCAN_DAYS) -> None:
    state = read_tail_state()
    now = time.time()
    since_epoch = (now - since_days * 86400) if since_days else None
    for path in _iter_jsonl(CLAUDE_ROOT, since_epoch):
        _process_jsonl(path, "claude", _parse_claude_record, state, now)
    for path in _iter_jsonl(CODEX_ROOT, since_epoch):
        _process_jsonl(path, "codex", _parse_codex_record, state, now)
    _process_cursor(state, now)
    write_tail_state(state)
    rebuild_index()


def run_daemon(poll_seconds: int = POLL_SECONDS, since_days: int | None = DEFAULT_SCAN_DAYS) -> int:
    print(f"threadline history-daemon running (poll {poll_seconds}s, debounce {DEBOUNCE_SECONDS}s, scan {since_days}d)")
    print(f"  claude: {CLAUDE_ROOT}")
    print(f"  codex:  {CODEX_ROOT}")
    print(f"  cursor: {CURSOR_ROOT}")
    try:
        while True:
            try:
                run_once(since_days=since_days)
            except Exception as exc:  # noqa: BLE001
                print(f"[tail] error: {exc!r}")
            time.sleep(poll_seconds)
    except KeyboardInterrupt:
        return 0
