from __future__ import annotations

from pathlib import Path

from threadline.xray.claude_adapter import parse_claude
from threadline.xray.evidence import assemble
from threadline.xray.events import Prompt, ToolCall
from threadline.xray.mapper import attribute, parse_diff

FIXTURES = Path(__file__).parent / "fixtures"

SAMPLE_DIFF = """\
diff --git a/greet.py b/greet.py
--- a/greet.py
+++ b/greet.py
@@ -1,1 +1,2 @@
-pass
+def hello():
+    return 'hi'
"""


def test_finds_test_run_after_edit_in_same_prompt():
    events = parse_claude(FIXTURES / "claude_minimal.jsonl")
    hunks = parse_diff(SAMPLE_DIFF)
    attrs = attribute(events, hunks, repo_root="/repo")

    evidence = assemble(events, attrs)

    assert len(evidence) == 1
    e = evidence[0]
    # The pytest run in the fixture is in the same prompt as the Edit.
    assert len(e.test_runs) == 1
    assert e.test_runs[0].tool == "Bash"
    assert e.test_runs[0].exit_status == 0
    assert e.has_test_failure is False
    assert e.retry_count == 0


def test_retry_count_counts_extra_edits_to_same_file():
    p = Prompt(id="p1", source="claude", text="fix it", timestamp="t0")
    edits = [
        ToolCall(id=f"e{i}", source="claude", prompt_id="p1", tool="Edit",
                 timestamp=f"t{i}", file_path="/repo/greet.py",
                 input={"file_path": "/repo/greet.py", "old_string": "x", "new_string": "y"})
        for i in range(3)
    ]
    events = [p, *edits]
    hunks = parse_diff(SAMPLE_DIFF)
    attrs = attribute(events, hunks, repo_root="/repo")
    evidence = assemble(events, attrs)

    assert evidence[0].retry_count == 2  # 3 edits = 1 attempt + 2 retries


def test_failing_test_flips_has_test_failure():
    p = Prompt(id="p1", source="claude", text="add hello", timestamp="t0")
    edit = ToolCall(id="e1", source="claude", prompt_id="p1", tool="Edit",
                    timestamp="t1", file_path="/repo/greet.py",
                    input={"file_path": "/repo/greet.py", "old_string": "x", "new_string": "y"})
    bash = ToolCall(id="b1", source="claude", prompt_id="p1", tool="Bash",
                    timestamp="t2",
                    input={"command": "pytest"}, output="1 failed", exit_status=1)
    events: list = [p, edit, bash]
    hunks = parse_diff(SAMPLE_DIFF)
    attrs = attribute(events, hunks, repo_root="/repo")
    evidence = assemble(events, attrs)

    assert evidence[0].has_test_failure is True
    assert evidence[0].test_runs[0].exit_status == 1


def test_non_test_bash_commands_are_ignored():
    """A `git status` or `ls` in the same prompt shouldn't be reported as a test."""
    p = Prompt(id="p1", source="claude", text="x", timestamp="t0")
    edit = ToolCall(id="e1", source="claude", prompt_id="p1", tool="Edit",
                    timestamp="t1", file_path="/repo/greet.py",
                    input={"file_path": "/repo/greet.py", "old_string": "x", "new_string": "y"})
    ls = ToolCall(id="b1", source="claude", prompt_id="p1", tool="Bash",
                  timestamp="t2", input={"command": "git status"},
                  output="clean", exit_status=0)
    events: list = [p, edit, ls]
    hunks = parse_diff(SAMPLE_DIFF)
    attrs = attribute(events, hunks, repo_root="/repo")
    evidence = assemble(events, attrs)

    assert evidence[0].test_runs == []
