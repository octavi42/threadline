from __future__ import annotations

import json
from pathlib import Path
from typing import Any

CACHE_DIR = Path.home() / ".cache" / "threadline"
SUMMARY_PATH = CACHE_DIR / "summary.txt"
STATE_PATH = CACHE_DIR / "state.json"


def ensure_cache_dir() -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)


def read_summary() -> str | None:
    if not SUMMARY_PATH.exists():
        return None
    return SUMMARY_PATH.read_text(encoding="utf-8").strip()


def read_state() -> dict[str, Any] | None:
    if not STATE_PATH.exists():
        return None
    try:
        return json.loads(STATE_PATH.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None


def write_cache(summary: str, state: dict[str, Any]) -> None:
    ensure_cache_dir()
    SUMMARY_PATH.write_text(summary.rstrip() + "\n", encoding="utf-8")
    STATE_PATH.write_text(
        json.dumps(state, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

