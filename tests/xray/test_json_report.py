from __future__ import annotations

import json
from pathlib import Path

from threadline.xray.claude_adapter import parse_claude
from threadline.xray.evidence import assemble
from threadline.xray.json_report import render_json, report_dict
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


def test_json_schema_shape():
    events = parse_claude(FIXTURES / "claude_minimal.jsonl")
    hunks = parse_diff(SAMPLE_DIFF)
    attrs = attribute(events, hunks, repo_root="/repo")
    evidence = assemble(events, attrs)

    data = report_dict(evidence, repo="/repo", base="HEAD", session="/tmp/s.jsonl")

    assert data["schema_version"] == 1
    assert data["repo"] == "/repo"
    assert data["base"] == "HEAD"
    assert data["session"] == "/tmp/s.jsonl"
    assert "generated_at" in data
    assert len(data["files"]) == 1

    f = data["files"][0]
    assert f["path"] == "greet.py"
    assert f["retry_count"] == 0
    assert f["has_test_failure"] is False
    assert f["framing_prompts"] == [
        {"source": "claude", "text": "add a hello function to greet.py"}
    ]
    assert f["edit_counts"] == [{"tool": "Edit", "count": 1}]
    assert len(f["hunks"]) == 1
    h = f["hunks"][0]
    assert h == {
        "base_start": 1,
        "base_count": 1,
        "new_start": 1,
        "new_count": 2,
        "body": [
            "-pass",
            "+def hello():",
            "+    return 'hi'",
        ],
        "tests": [
            {
                "tool": "Bash",
                "command": "pytest",
                "output": "1 passed",
                "exit_status": 0,
                "timestamp": "2026-05-15T10:00:03.000Z",
            }
        ],
    }


def test_render_json_is_valid_json():
    events = parse_claude(FIXTURES / "claude_minimal.jsonl")
    hunks = parse_diff(SAMPLE_DIFF)
    attrs = attribute(events, hunks, repo_root="/repo")
    evidence = assemble(events, attrs)
    out = render_json(evidence, repo="/repo", base="HEAD", session="/tmp/s.jsonl")

    # Must be parseable back from the string.
    parsed = json.loads(out)
    assert parsed["schema_version"] == 1
