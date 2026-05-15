from __future__ import annotations

from pathlib import Path

from threadline.xray.claude_adapter import parse_claude
from threadline.xray.evidence import assemble
from threadline.xray.html_report import render_html
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


def test_html_is_self_contained_and_valid():
    events = parse_claude(FIXTURES / "claude_minimal.jsonl")
    hunks = parse_diff(SAMPLE_DIFF)
    attrs = attribute(events, hunks, repo_root="/repo")
    evidence = assemble(events, attrs)

    out = render_html(evidence, repo="/repo", base="HEAD", session="/path/to.jsonl")

    assert out.startswith("<!DOCTYPE html>")
    assert "</html>" in out
    # Self-contained: no remote refs.
    assert "http://" not in out
    assert "https://" not in out
    # Critical content present.
    assert "Agent X-Ray" in out
    assert "greet.py" in out
    assert "add a hello function to greet.py" in out
    assert "1× Edit" in out
    # Diff body must render with line type classes.
    assert 'class="diff-line add"' in out
    assert 'class="diff-line del"' in out
    assert "def hello():" in out


def test_html_escapes_user_text():
    """Prompt text with HTML metacharacters must be escaped, not injected."""
    from threadline.xray.events import Prompt, ToolCall
    from threadline.xray.mapper import HunkAttribution, Hunk

    p = Prompt(id="p", source="claude", text="<script>alert(1)</script>", timestamp="t")
    edit = ToolCall(id="e", source="claude", prompt_id="p", tool="Edit", timestamp="t",
                    file_path="/repo/greet.py",
                    input={"file_path": "/repo/greet.py", "old_string": "a", "new_string": "b"})
    hunks = parse_diff(SAMPLE_DIFF)
    attrs = attribute([p, edit], hunks, repo_root="/repo")
    evidence = assemble([p, edit], attrs)

    out = render_html(evidence, repo="/repo", base="HEAD", session=None)

    assert "<script>alert(1)</script>" not in out
    assert "&lt;script&gt;" in out


def test_html_handles_empty_evidence():
    out = render_html([], repo="/repo", base="HEAD", session=None)
    assert "No overlap" in out
    assert out.startswith("<!DOCTYPE html>")
