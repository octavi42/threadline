from __future__ import annotations

from pathlib import Path

from threadline.xray.codex_adapter import parse_codex
from threadline.xray.events import Prompt, ToolCall

FIXTURE = Path(__file__).parent / "fixtures" / "codex_minimal.jsonl"


def test_emits_prompt_function_call_and_apply_patch():
    events = parse_codex(FIXTURE)

    assert len(events) == 3
    prompt, exec_call, patch_call = events

    assert isinstance(prompt, Prompt)
    assert prompt.id == "t1"
    assert prompt.source == "codex"
    assert prompt.text == "add hello function"
    assert prompt.cwd == "/repo"
    assert prompt.git_branch == "main"

    assert isinstance(exec_call, ToolCall)
    assert exec_call.tool == "exec_command"
    assert exec_call.input["cmd"] == "ls"
    assert exec_call.output == "greet.py"
    assert exec_call.exit_status == 0
    assert exec_call.prompt_id == "t1"

    assert isinstance(patch_call, ToolCall)
    assert patch_call.tool == "apply_patch"
    assert patch_call.file_path == "/repo/greet.py"
    # patch_apply_end enrichment attaches the structured changes blob.
    assert "_patch_changes" in patch_call.input
    changes = patch_call.input["_patch_changes"]
    assert "/repo/greet.py" in changes
    assert changes["/repo/greet.py"]["type"] == "update"
    assert "def hello" in changes["/repo/greet.py"]["content"]
    assert patch_call.exit_status == 0


def test_apply_patch_extracts_file_path_from_textual_patch():
    """Even before patch_apply_end fires, the apply_patch ToolCall should know
    which file it targets (parsed from the textual *** Update File header)."""
    import json
    import tempfile

    rows = [
        {"timestamp": "t", "type": "event_msg", "payload": {"type": "task_started", "turn_id": "tt"}},
        {"timestamp": "t", "type": "response_item", "payload": {
            "type": "custom_tool_call", "call_id": "c", "name": "apply_patch",
            "input": "*** Begin Patch\n*** Add File: /repo/new.py\n+x\n*** End Patch",
        }},
    ]
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
        path = Path(f.name)

    events = parse_codex(path)
    calls = [e for e in events if isinstance(e, ToolCall)]
    assert len(calls) == 1
    assert calls[0].file_path == "/repo/new.py"
