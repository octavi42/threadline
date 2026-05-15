from __future__ import annotations

from pathlib import Path

from threadline.xray.claude_adapter import parse_claude
from threadline.xray.events import Prompt, ToolCall

FIXTURE = Path(__file__).parent / "fixtures" / "claude_minimal.jsonl"


def test_emits_prompt_and_paired_tool_calls():
    events = parse_claude(FIXTURE)

    assert len(events) == 3
    prompt, edit, bash = events

    assert isinstance(prompt, Prompt)
    assert prompt.id == "p1"
    assert prompt.source == "claude"
    assert prompt.text == "add a hello function to greet.py"
    assert prompt.cwd == "/repo"
    assert prompt.git_branch == "main"

    assert isinstance(edit, ToolCall)
    assert edit.id == "tu_edit_1"
    assert edit.tool == "Edit"
    assert edit.source == "claude"
    assert edit.prompt_id == "p1"
    assert edit.file_path == "/repo/greet.py"
    assert edit.input["old_string"] == "pass"
    assert edit.output is not None
    assert edit.exit_status is None  # Edit has no exit code

    assert isinstance(bash, ToolCall)
    assert bash.id == "tu_bash_1"
    assert bash.tool == "Bash"
    assert bash.exit_status == 0
    assert bash.output is not None
    assert "1 passed" in bash.output


def test_tool_call_without_result_is_still_emitted():
    """Interrupted sessions leave a tool_use with no paired result."""
    import json
    import tempfile

    rows = [
        {"type": "assistant", "timestamp": "t", "promptId": "p", "parentUuid": None,
         "message": {"role": "assistant", "content": [
             {"type": "tool_use", "id": "orphan", "name": "Bash", "input": {"command": "echo hi"}}
         ]}}
    ]
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
        path = Path(f.name)

    events = parse_claude(path)
    assert len(events) == 1
    assert isinstance(events[0], ToolCall)
    assert events[0].id == "orphan"
    assert events[0].output is None
