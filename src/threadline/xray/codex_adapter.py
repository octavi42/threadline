"""Codex CLI rollout JSONL -> normalized Prompt/ToolCall events.

Codex payload types we care about:
- session_meta: cwd, git, model — header info
- user_message: text (we treat as a Prompt)
- response_item with payload.type=function_call: tool calls (exec_command, write_stdin)
- response_item with payload.type=function_call_output: paired by call_id
- response_item with payload.type=custom_tool_call: edits (name=apply_patch)
- response_item with payload.type=custom_tool_call_output: paired by call_id
- response_item with payload.type=patch_apply_end: structured edit result
  (changes[path] = {type, content, ...}) — captured into the apply_patch call

Turn boundary: payload.type=task_started carries turn_id; we use it as prompt_id.
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


def _first_path_from_patch(text: str) -> str | None:
    for line in text.splitlines():
        stripped = line.strip()
        for prefix in ("*** Add File: ", "*** Update File: ", "*** Delete File: "):
            if stripped.startswith(prefix):
                return stripped[len(prefix):].strip() or None
    return None


def parse_codex(path: Path) -> list[Event]:
    events: list[Event] = []
    pending: dict[str, ToolCall] = {}  # call_id -> ToolCall

    last_cwd: str | None = None
    last_branch: str | None = None
    current_prompt_id: str | None = None

    for row in _iter_jsonl(path):
        payload = row.get("payload") or {}
        if not isinstance(payload, dict):
            continue
        ts = row.get("timestamp") or ""
        ptype = payload.get("type")

        # session_meta has the cwd/git at the top of the rollout.
        if "cwd" in payload and isinstance(payload.get("cwd"), str):
            last_cwd = payload["cwd"]
        git = payload.get("git")
        if isinstance(git, dict):
            branch = git.get("branch")
            if isinstance(branch, str):
                last_branch = branch

        if ptype == "task_started":
            turn_id = payload.get("turn_id")
            if isinstance(turn_id, str):
                current_prompt_id = turn_id

        elif ptype == "user_message":
            text = payload.get("text") or payload.get("message") or ""
            if not isinstance(text, str):
                text = ""
            if text.strip() and current_prompt_id:
                events.append(
                    Prompt(
                        id=current_prompt_id,
                        source="codex",
                        text=text.strip(),
                        timestamp=ts,
                        cwd=last_cwd,
                        git_branch=last_branch,
                    )
                )

        elif ptype == "function_call":
            call_id = str(payload.get("call_id", ""))
            name = str(payload.get("name", ""))
            raw_args = payload.get("arguments")
            tinput: dict[str, Any] = {}
            if isinstance(raw_args, str):
                try:
                    parsed = json.loads(raw_args)
                except json.JSONDecodeError:
                    tinput = {"_raw": raw_args}
                else:
                    tinput = parsed if isinstance(parsed, dict) else {"_raw": parsed}
            elif isinstance(raw_args, dict):
                tinput = raw_args
            file_path = tinput.get("file_path") or tinput.get("path") or tinput.get("workdir")
            pending[call_id] = ToolCall(
                id=call_id,
                source="codex",
                prompt_id=current_prompt_id,
                tool=name,
                timestamp=ts,
                file_path=file_path if isinstance(file_path, str) else None,
                input=tinput,
            )

        elif ptype == "function_call_output":
            call_id = str(payload.get("call_id", ""))
            call = pending.pop(call_id, None)
            if call is None:
                continue
            output = payload.get("output")
            out_text: str | None = None
            exit_code: int | None = None
            if isinstance(output, str):
                # Codex sometimes serializes output as a JSON string with metadata.
                try:
                    parsed = json.loads(output)
                except json.JSONDecodeError:
                    out_text = output
                else:
                    if isinstance(parsed, dict):
                        out_text = parsed.get("output") if isinstance(parsed.get("output"), str) else None
                        meta = parsed.get("metadata") or {}
                        if isinstance(meta, dict) and isinstance(meta.get("exit_code"), int):
                            exit_code = meta["exit_code"]
                    else:
                        out_text = output
            elif isinstance(output, dict):
                out_text = output.get("output") if isinstance(output.get("output"), str) else json.dumps(output)[:4000]
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
                )
            )

        elif ptype == "custom_tool_call":
            call_id = str(payload.get("call_id", ""))
            name = str(payload.get("name", ""))
            raw_input = payload.get("input")
            tinput: dict[str, Any] = {}
            file_path: str | None = None
            if isinstance(raw_input, str):
                tinput = {"_raw": raw_input}
                if name == "apply_patch":
                    file_path = _first_path_from_patch(raw_input)
            elif isinstance(raw_input, dict):
                tinput = raw_input
                fp = raw_input.get("file_path") or raw_input.get("path")
                if isinstance(fp, str):
                    file_path = fp
            pending[call_id] = ToolCall(
                id=call_id,
                source="codex",
                prompt_id=current_prompt_id,
                tool=name,
                timestamp=ts,
                file_path=file_path,
                input=tinput,
            )

        elif ptype == "custom_tool_call_output":
            call_id = str(payload.get("call_id", ""))
            call = pending.pop(call_id, None)
            if call is None:
                continue
            output = payload.get("output")
            out_text = output if isinstance(output, str) else (json.dumps(output)[:4000] if output else None)
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
                )
            )

        elif ptype == "patch_apply_end":
            # Enriches a recently-emitted apply_patch ToolCall in place via call_id.
            call_id = str(payload.get("call_id", ""))
            # Walk back through emitted events to find the matching ToolCall.
            for i in range(len(events) - 1, -1, -1):
                ev = events[i]
                if isinstance(ev, ToolCall) and ev.id == call_id:
                    changes = payload.get("changes") or {}
                    success = payload.get("success")
                    enriched_input = {**ev.input, "_patch_changes": changes}
                    events[i] = ToolCall(
                        id=ev.id,
                        source=ev.source,
                        prompt_id=ev.prompt_id,
                        tool=ev.tool,
                        timestamp=ev.timestamp,
                        file_path=ev.file_path or (next(iter(changes), None) if isinstance(changes, dict) else None),
                        input=enriched_input,
                        output=ev.output,
                        exit_status=0 if success else (1 if success is False else ev.exit_status),
                    )
                    break

    for call in pending.values():
        events.append(call)

    return events
