"""Claude Code JSONL -> normalized Prompt/ToolCall events.

Claude rows we care about:
- type=user, message.role=user, message.content is str or list[block]
  - user prompt text comes from str content or text blocks
  - tool results come from blocks with type=tool_result (paired by tool_use_id)
- type=assistant, message.content is list[block]
  - tool calls come from blocks with type=tool_use (id, name, input)

We pair (assistant tool_use) with (the next user tool_result carrying the same
id) to attach output/exit_status to the ToolCall.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .events import Event, Prompt, ToolCall


def _iter_jsonl(path: Path):
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def _result_text(result: Any) -> tuple[str | None, int | None]:
    """Extract textual output and exit status from a tool_result content blob."""
    if result is None:
        return None, None
    if isinstance(result, str):
        return result, None
    if isinstance(result, dict):
        # Bash-style toolUseResult: {stdout, stderr, interrupted, ...}
        if "stdout" in result or "stderr" in result:
            parts = []
            if result.get("stdout"):
                parts.append(str(result["stdout"]))
            if result.get("stderr"):
                parts.append(str(result["stderr"]))
            output_text = "\n".join(parts) or None
            exit_code = result.get("exitCode")
            if isinstance(exit_code, int):
                return output_text, exit_code
            # Claude Code Bash results don't always carry exitCode; infer from
            # interrupted + stderr instead.
            if result.get("interrupted") is True:
                return output_text, -1
            if result.get("interrupted") is False and not result.get("stderr"):
                return output_text, 0
            return output_text, None
        # Edit/Write/Read: just stringify
        return json.dumps(result, default=str)[:4000], None
    if isinstance(result, list):
        texts = []
        for block in result:
            if isinstance(block, dict) and block.get("type") == "text":
                texts.append(str(block.get("text", "")))
        return ("\n".join(texts) or None), None
    return None, None


def _file_path_for(tool: str, tool_input: dict) -> str | None:
    if not isinstance(tool_input, dict):
        return None
    return tool_input.get("file_path") or tool_input.get("path") or tool_input.get("notebook_path")


def parse_claude(path: Path) -> list[Event]:
    events: list[Event] = []
    pending_calls: dict[str, ToolCall] = {}  # tool_use_id -> ToolCall

    last_cwd: str | None = None
    last_branch: str | None = None
    current_prompt_id: str | None = None

    for row in _iter_jsonl(path):
        if isinstance(row.get("cwd"), str):
            last_cwd = row["cwd"]
        if isinstance(row.get("gitBranch"), str):
            last_branch = row["gitBranch"]

        rtype = row.get("type")
        msg = row.get("message") or {}
        if not isinstance(msg, dict):
            continue
        role = msg.get("role")
        content = msg.get("content")
        ts = row.get("timestamp") or ""
        prompt_id = row.get("promptId")
        parent_uuid = row.get("parentUuid")
        is_side = bool(row.get("isSidechain"))

        if rtype == "user" and role == "user":
            text_parts: list[str] = []
            results_by_id: dict[str, Any] = {}
            if isinstance(content, str):
                text_parts.append(content)
            elif isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    btype = block.get("type")
                    if btype == "text":
                        text_parts.append(str(block.get("text", "")))
                    elif btype == "tool_result":
                        tu_id = str(block.get("tool_use_id", ""))
                        if tu_id and tu_id not in results_by_id:
                            results_by_id[tu_id] = block.get("content")
            # Row-level toolUseResult is structurally richer (exit code, etc.);
            # prefer it over in-message tool_result content for the same id.
            if row.get("toolUseResult") is not None and row.get("toolUseID"):
                results_by_id[str(row["toolUseID"])] = row["toolUseResult"]
            tool_results = list(results_by_id.items())

            text = "\n".join(t for t in text_parts if t).strip()
            if text and prompt_id:
                current_prompt_id = prompt_id
                events.append(
                    Prompt(
                        id=prompt_id,
                        source="claude",
                        text=text,
                        timestamp=ts,
                        cwd=last_cwd,
                        git_branch=last_branch,
                    )
                )

            for tu_id, result in tool_results:
                call = pending_calls.pop(tu_id, None)
                if call is None:
                    continue
                out_text, exit_code = _result_text(result)
                events.append(
                    ToolCall(
                        id=call.id,
                        source=call.source,
                        prompt_id=call.prompt_id,
                        tool=call.tool,
                        timestamp=call.timestamp,
                        file_path=call.file_path,
                        input=call.input,
                        output=out_text,
                        exit_status=exit_code,
                        parent_id=call.parent_id,
                        is_sidechain=call.is_sidechain,
                    )
                )

        elif rtype == "assistant" and role == "assistant":
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                tu_id = str(block.get("id", ""))
                tool = str(block.get("name", ""))
                tinput = block.get("input") or {}
                if not isinstance(tinput, dict):
                    tinput = {"_raw": tinput}
                call = ToolCall(
                    id=tu_id,
                    source="claude",
                    prompt_id=prompt_id or current_prompt_id,
                    tool=tool,
                    timestamp=ts,
                    file_path=_file_path_for(tool, tinput),
                    input=tinput,
                    parent_id=parent_uuid,
                    is_sidechain=is_side,
                )
                pending_calls[tu_id] = call

    # Flush any tool calls that never got a paired result (interrupted sessions).
    for call in pending_calls.values():
        events.append(call)

    return events
