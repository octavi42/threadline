from __future__ import annotations

from threadline.xray.events import Prompt, ToolCall
from threadline.xray.mapper import attribute, parse_diff

SAMPLE_DIFF = """\
diff --git a/greet.py b/greet.py
--- a/greet.py
+++ b/greet.py
@@ -1,1 +1,2 @@
-pass
+def hello():
+    return 'hi'
"""


def _edit(prompt_id: str, ts: str) -> ToolCall:
    return ToolCall(
        id=f"e-{prompt_id}", source="claude", prompt_id=prompt_id, tool="Edit",
        timestamp=ts, file_path="/repo/greet.py",
        input={"file_path": "/repo/greet.py", "old_string": "x", "new_string": "y"},
    )


def test_framing_walks_back_past_yes():
    events: list = [
        Prompt(id="p1", source="claude", text="add a hello function to greet.py", timestamp="t0"),
        Prompt(id="p2", source="claude", text="yes", timestamp="t1"),
        _edit("p2", "t2"),
    ]
    hunks = parse_diff(SAMPLE_DIFF)
    attrs = attribute(events, hunks, repo_root="/repo")
    a = attrs[0]

    # Immediate prompt is "yes"; framing should resolve back to the task frame.
    assert [p.text for p in a.prompts] == ["yes"]
    assert [p.text for p in a.framing_prompts] == ["add a hello function to greet.py"]


def test_substantive_prompt_remains_itself():
    events: list = [
        Prompt(id="p1", source="claude", text="add a hello function to greet.py", timestamp="t0"),
        _edit("p1", "t1"),
    ]
    hunks = parse_diff(SAMPLE_DIFF)
    attrs = attribute(events, hunks, repo_root="/repo")
    assert [p.text for p in attrs[0].framing_prompts] == ["add a hello function to greet.py"]


def test_framing_dedupes_when_multiple_edits_share_same_frame():
    events: list = [
        Prompt(id="p1", source="claude", text="build the agent xray module", timestamp="t0"),
        Prompt(id="p2", source="claude", text="yes", timestamp="t1"),
        Prompt(id="p3", source="claude", text="do it", timestamp="t2"),
        _edit("p2", "t3"),
        _edit("p3", "t4"),
    ]
    hunks = parse_diff(SAMPLE_DIFF)
    attrs = attribute(events, hunks, repo_root="/repo")
    a = attrs[0]

    # Both "yes" and "do it" point at the same earlier framing prompt.
    assert len(a.prompts) == 2
    assert len(a.framing_prompts) == 1
    assert a.framing_prompts[0].text == "build the agent xray module"


def test_no_substantive_predecessor_keeps_immediate():
    """If the session opens with only short prompts, framing falls back to immediate."""
    events: list = [
        Prompt(id="p1", source="claude", text="yes", timestamp="t0"),
        _edit("p1", "t1"),
    ]
    hunks = parse_diff(SAMPLE_DIFF)
    attrs = attribute(events, hunks, repo_root="/repo")
    assert [p.text for p in attrs[0].framing_prompts] == ["yes"]
