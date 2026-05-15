from __future__ import annotations

from pathlib import Path

from threadline.xray.claude_adapter import parse_claude
from threadline.xray.cli import render
from threadline.xray.evidence import assemble
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


def test_render_contains_prompt_edit_and_test_lines():
    events = parse_claude(FIXTURES / "claude_minimal.jsonl")
    hunks = parse_diff(SAMPLE_DIFF)
    attrs = attribute(events, hunks, repo_root="/repo")
    evidence = assemble(events, attrs)

    out = render(evidence)

    assert "── greet.py ──" in out
    assert "prompt (claude):" in out
    assert "add a hello function" in out
    assert "1× Edit" in out
    assert "✓" in out  # passed test marker
    assert "pytest" in out


def test_render_empty_evidence_returns_friendly_message():
    out = render([])
    assert "no overlap" in out
