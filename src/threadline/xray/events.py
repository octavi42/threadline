"""Normalized event schema for Claude Code and Codex CLI sessions.

Per-source adapters in ``claude_adapter`` and ``codex_adapter`` convert raw
JSONL into the two record types defined here. Everything downstream (mapper,
evidence) only sees these normalized types.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal

Source = Literal["claude", "codex"]


@dataclass(frozen=True)
class Prompt:
    id: str
    source: Source
    text: str
    timestamp: str
    cwd: str | None = None
    git_branch: str | None = None


@dataclass(frozen=True)
class ToolCall:
    id: str
    source: Source
    prompt_id: str | None
    tool: str
    timestamp: str
    file_path: str | None = None
    input: dict[str, Any] = field(default_factory=dict)
    output: str | None = None
    exit_status: int | None = None
    parent_id: str | None = None
    is_sidechain: bool = False


Event = Prompt | ToolCall


def parse(path: str | Path) -> list[Event]:
    """Auto-detect source by directory hint or first row, dispatch to adapter."""
    p = Path(path)
    name = str(p)
    if "/.codex/" in name or p.name.startswith("rollout-"):
        from .codex_adapter import parse_codex
        return parse_codex(p)
    from .claude_adapter import parse_claude
    return parse_claude(p)
