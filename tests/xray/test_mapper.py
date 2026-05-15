from __future__ import annotations

from pathlib import Path

from threadline.xray.claude_adapter import parse_claude
from threadline.xray.codex_adapter import parse_codex
from threadline.xray.events import Prompt, ToolCall
from threadline.xray.mapper import Hunk, attribute, parse_diff

FIXTURES = Path(__file__).parent / "fixtures"

SAMPLE_DIFF = """\
diff --git a/greet.py b/greet.py
index e69de29..a9b1c2d 100644
--- a/greet.py
+++ b/greet.py
@@ -1,1 +1,2 @@
-pass
+def hello():
+    return 'hi'
diff --git a/other.py b/other.py
index 0000000..1111111 100644
--- a/other.py
+++ b/other.py
@@ -10,3 +12,4 @@ def f():
     a = 1
+    b = 2
     c = 3
"""


def test_parse_diff_extracts_hunks_per_file():
    hunks = parse_diff(SAMPLE_DIFF)

    assert set(hunks.keys()) == {"greet.py", "other.py"}
    assert len(hunks["greet.py"]) == 1
    h = hunks["greet.py"][0]
    assert h.base_start == 1 and h.base_count == 1
    assert h.new_start == 1 and h.new_count == 2

    h2 = hunks["other.py"][0]
    assert h2.base_start == 10 and h2.base_count == 3
    assert h2.new_start == 12 and h2.new_count == 4


def test_parse_diff_handles_unified_zero_default_count():
    """git diff --unified=0 may emit headers without an explicit count, defaulting to 1."""
    text = """\
diff --git a/x.py b/x.py
--- a/x.py
+++ b/x.py
@@ -5 +5 @@
-old
+new
"""
    hunks = parse_diff(text)
    h = hunks["x.py"][0]
    assert h.base_start == 5 and h.base_count == 1
    assert h.new_start == 5 and h.new_count == 1


def test_attribute_claude_edit_to_hunk():
    events = parse_claude(FIXTURES / "claude_minimal.jsonl")
    hunks = parse_diff(SAMPLE_DIFF)

    attrs = attribute(events, hunks, repo_root="/repo")

    by_file = {a.hunk.file_path: a for a in attrs}
    assert "greet.py" in by_file
    g = by_file["greet.py"]

    # The Claude Edit on /repo/greet.py should be attributed.
    edit_tools = [e.tool for e in g.edits]
    assert "Edit" in edit_tools
    # Bash test runs are NOT attributed to hunks (they're not edits).
    assert "Bash" not in edit_tools

    # The originating prompt should be surfaced exactly once.
    assert len(g.prompts) == 1
    assert g.prompts[0].text == "add a hello function to greet.py"

    # other.py has no edits in the session — empty attribution.
    assert "other.py" in by_file
    assert by_file["other.py"].edits == []
    assert by_file["other.py"].prompts == []


def test_attribute_codex_apply_patch_to_hunk():
    events = parse_codex(FIXTURES / "codex_minimal.jsonl")
    hunks = parse_diff(SAMPLE_DIFF)

    attrs = attribute(events, hunks, repo_root="/repo")

    g = next(a for a in attrs if a.hunk.file_path == "greet.py")
    tools = [e.tool for e in g.edits]
    assert "apply_patch" in tools
    assert len(g.prompts) == 1
    assert g.prompts[0].text == "add hello function"


def test_attribute_skips_non_edit_tools():
    """Read/ToolSearch/Agent calls shouldn't appear in hunk attributions."""
    events: list = [
        Prompt(id="p1", source="claude", text="x", timestamp="t"),
        ToolCall(id="r1", source="claude", prompt_id="p1", tool="Read",
                 timestamp="t", file_path="/repo/greet.py"),
        ToolCall(id="t1", source="claude", prompt_id="p1", tool="ToolSearch",
                 timestamp="t"),
        ToolCall(id="e1", source="claude", prompt_id="p1", tool="Edit",
                 timestamp="t", file_path="/repo/greet.py",
                 input={"file_path": "/repo/greet.py", "old_string": "a", "new_string": "b"}),
    ]
    hunks = parse_diff(SAMPLE_DIFF)
    attrs = attribute(events, hunks, repo_root="/repo")
    g = next(a for a in attrs if a.hunk.file_path == "greet.py")
    assert [e.tool for e in g.edits] == ["Edit"]


def test_attribute_codex_multi_file_patch():
    """A single apply_patch with _patch_changes covering multiple files is
    attributed to every file it touched, not just the one declared in file_path."""
    call = ToolCall(
        id="c1", source="codex", prompt_id="t1", tool="apply_patch",
        timestamp="t", file_path="/repo/greet.py",
        input={"_patch_changes": {
            "/repo/greet.py": {"type": "update", "content": "..."},
            "/repo/other.py": {"type": "add", "content": "..."},
        }},
    )
    events: list = [
        Prompt(id="t1", source="codex", text="big change", timestamp="t"),
        call,
    ]
    hunks = parse_diff(SAMPLE_DIFF)
    attrs = attribute(events, hunks, repo_root="/repo")
    by_file = {a.hunk.file_path: a for a in attrs}

    assert "apply_patch" in [e.tool for e in by_file["greet.py"].edits]
    assert "apply_patch" in [e.tool for e in by_file["other.py"].edits]
