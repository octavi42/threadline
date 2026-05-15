"""Throwaway: dump real Claude Code + Codex sessions to discover schema edges.

Run:
    python scripts/dump_session.py <claude_jsonl> [codex_jsonl]

Prints tool_use blocks (Edit/Write/Bash) and the user prompt that preceded each
cluster, so we can see what the parser will actually have to handle.
"""
from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path


def load_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                print(f"  ! parse error line {len(rows)+1}: {exc}", file=sys.stderr)
    return rows


def summarize_claude(rows: list[dict]) -> None:
    print(f"\n=== CLAUDE ({len(rows)} rows) ===")
    type_counts: Counter[str] = Counter()
    tool_counts: Counter[str] = Counter()
    role_counts: Counter[str] = Counter()
    sample_tool_inputs: dict[str, dict] = {}
    first_keys = set()
    last_user_text: str | None = None

    for i, row in enumerate(rows):
        first_keys.update(row.keys())
        t = row.get("type", "<no-type>")
        type_counts[t] += 1
        msg = row.get("message") or {}
        role = msg.get("role", "")
        role_counts[role] += 1

        content = msg.get("content")
        if isinstance(content, str) and role == "user":
            last_user_text = content[:120]
        elif isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                btype = block.get("type", "")
                if btype == "tool_use":
                    name = block.get("name", "?")
                    tool_counts[name] += 1
                    if name not in sample_tool_inputs:
                        sample_tool_inputs[name] = block.get("input", {})
                elif btype == "text" and role == "user":
                    text = block.get("text", "")
                    if text:
                        last_user_text = text[:120]

    print(f"top-level keys observed: {sorted(first_keys)}")
    print(f"types: {dict(type_counts)}")
    print(f"roles: {dict(role_counts)}")
    print(f"tools: {dict(tool_counts)}")
    print("\n-- sample tool inputs (first occurrence of each) --")
    for name, inp in sample_tool_inputs.items():
        keys = sorted(inp.keys()) if isinstance(inp, dict) else type(inp).__name__
        print(f"  {name}: keys={keys}")
        if isinstance(inp, dict):
            for k, v in inp.items():
                preview = repr(v)[:80]
                print(f"      {k} = {preview}")
    if last_user_text:
        print(f"\nlast user text (preview): {last_user_text!r}")


def summarize_codex(rows: list[dict]) -> None:
    print(f"\n=== CODEX ({len(rows)} rows) ===")
    type_counts: Counter[str] = Counter()
    payload_type_counts: Counter[str] = Counter()
    record_type_counts: Counter[str] = Counter()
    first_keys = set()
    sample_by_type: dict[str, dict] = {}

    for row in rows:
        first_keys.update(row.keys())
        t = row.get("type", "<no-type>")
        type_counts[t] += 1
        payload = row.get("payload") or {}
        if isinstance(payload, dict):
            pt = payload.get("type", "<no-type>")
            payload_type_counts[pt] += 1
            if pt not in sample_by_type:
                sample_by_type[pt] = payload
        rt = row.get("record_type")
        if rt:
            record_type_counts[rt] += 1

    print(f"top-level keys observed: {sorted(first_keys)}")
    print(f"row types: {dict(type_counts)}")
    print(f"record_types: {dict(record_type_counts)}")
    print(f"payload types: {dict(payload_type_counts)}")
    print("\n-- sample payloads (first of each type) --")
    for pt, payload in sample_by_type.items():
        keys = sorted(payload.keys()) if isinstance(payload, dict) else type(payload).__name__
        print(f"  {pt}: keys={keys}")


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    claude_path = Path(sys.argv[1])
    summarize_claude(load_jsonl(claude_path))
    if len(sys.argv) >= 3:
        codex_path = Path(sys.argv[2])
        summarize_codex(load_jsonl(codex_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
