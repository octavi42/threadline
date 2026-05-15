"""Self-contained HTML rendering for X-Ray reports.

Produces a single dark-themed HTML page with per-file collapsible cards,
color-coded test status pills, and the framing prompt rendered as a callout.
No external CSS / JS / fonts — embeddable, shareable, screenshottable.
"""
from __future__ import annotations

import html
from datetime import datetime

from .evidence import HunkEvidence


def _truncate(text: str, n: int) -> str:
    text = text.replace("\n", " ").strip()
    return text if len(text) <= n else text[: n - 1] + "…"


def _status_class(exit_status: int | None) -> tuple[str, str]:
    if exit_status == 0:
        return "pass", "✓"
    if exit_status == -1:
        return "warn", "⚠"
    if exit_status is not None:
        return "fail", "✗"
    return "unknown", "·"


_CSS = """
:root {
  --bg: #0d1117;
  --bg-card: #161b22;
  --bg-hunk: #1c222b;
  --fg: #c9d1d9;
  --fg-muted: #8b949e;
  --accent: #58a6ff;
  --pass: #3fb950;
  --fail: #f85149;
  --warn: #d29922;
  --neutral: #6e7681;
  --border: #30363d;
  --code: 'SF Mono', 'Menlo', 'Monaco', 'Courier New', monospace;
}
* { box-sizing: border-box; }
body {
  margin: 0; padding: 2.5rem 1.5rem;
  background: var(--bg); color: var(--fg);
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  font-size: 14px; line-height: 1.5;
}
header { max-width: 1100px; margin: 0 auto 2rem; }
header h1 { margin: 0 0 0.5rem; font-size: 1.6rem; font-weight: 600; letter-spacing: -0.01em; }
header .tagline { color: var(--fg-muted); margin-bottom: 1rem; }
header .meta {
  color: var(--fg-muted); font-family: var(--code); font-size: 12px;
  padding: 0.6rem 0.8rem; background: var(--bg-card); border: 1px solid var(--border);
  border-radius: 6px; word-break: break-all;
}
header .meta span { color: var(--fg); }
main { max-width: 1100px; margin: 0 auto; display: flex; flex-direction: column; gap: 1rem; }
.file {
  background: var(--bg-card); border: 1px solid var(--border);
  border-radius: 10px; overflow: hidden;
}
.file > summary {
  padding: 0.9rem 1.2rem; font-family: var(--code); font-weight: 600;
  cursor: pointer; user-select: none; color: var(--accent);
  list-style: none; display: flex; align-items: center; gap: 0.6rem;
}
.file > summary::-webkit-details-marker { display: none; }
.file > summary::before {
  content: '▸'; color: var(--fg-muted); font-size: 10px;
  transition: transform 0.15s ease;
}
.file[open] > summary::before { transform: rotate(90deg); }
.file > summary .count { color: var(--fg-muted); font-weight: 400; font-size: 12px; margin-left: auto; }
.hunks { padding: 0 1.2rem 1.2rem; display: flex; flex-direction: column; gap: 0.8rem; }
.hunk {
  background: var(--bg-hunk); border-radius: 8px; padding: 0.9rem 1rem;
  border: 1px solid var(--border);
}
.hunk-range {
  font-family: var(--code); font-size: 11px; color: var(--fg-muted);
  margin-bottom: 0.7rem; letter-spacing: 0.02em;
}
.prompt {
  border-left: 3px solid var(--accent);
  padding: 0.5rem 0.85rem; margin-bottom: 0.7rem;
  background: rgba(88,166,255,0.06); border-radius: 0 6px 6px 0;
  line-height: 1.45;
}
.prompt + .prompt { margin-top: -0.4rem; }
.prompt .src {
  color: var(--accent); font-size: 10px; text-transform: uppercase;
  letter-spacing: 0.08em; font-weight: 700; margin-right: 0.6rem;
}
.no-prompt { color: var(--fg-muted); font-style: italic; padding: 0.5rem 0.85rem; font-size: 13px; }
.chips { display: flex; gap: 0.4rem; margin-bottom: 0.7rem; flex-wrap: wrap; }
.chip {
  font-size: 11px; padding: 0.18rem 0.55rem; border-radius: 12px;
  background: var(--border); color: var(--fg); font-family: var(--code);
}
.chip.retry { background: rgba(210,153,34,0.18); color: var(--warn); }
.tests { display: flex; flex-direction: column; gap: 0.3rem; }
.test {
  display: grid; grid-template-columns: 1.4rem minmax(0, 40%) minmax(0, 1fr);
  align-items: center; gap: 0.6rem;
  font-family: var(--code); font-size: 12px;
  background: rgba(255,255,255,0.025);
  padding: 0.45rem 0.7rem; border-radius: 5px;
}
.test .status { text-align: center; font-weight: 700; }
.test .status.pass { color: var(--pass); }
.test .status.fail { color: var(--fail); }
.test .status.warn { color: var(--warn); }
.test .status.unknown { color: var(--neutral); }
.test .cmd { color: var(--fg); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.test .out { color: var(--fg-muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.empty { color: var(--fg-muted); font-style: italic; font-size: 12px; padding: 0.3rem 0; }
footer { max-width: 1100px; margin: 2rem auto 0; color: var(--fg-muted); font-size: 12px; text-align: center; }
"""


def render_html(
    evidence: list[HunkEvidence],
    *,
    repo: str | None = None,
    base: str | None = None,
    session: str | None = None,
) -> str:
    """Render the report as a single self-contained HTML document."""
    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    meta_bits: list[str] = []
    if repo:
        meta_bits.append(f"repo <span>{html.escape(repo)}</span>")
    meta_bits.append(f"base <span>{html.escape(base or 'HEAD')}</span>")
    if session:
        meta_bits.append(f"session <span>{html.escape(session)}</span>")
    meta_bits.append(f"generated <span>{generated_at}</span>")
    meta_line = " · ".join(meta_bits)

    if not evidence:
        body = (
            '<main><div class="file" open><div class="hunks">'
            '<div class="empty">No overlap between the diff and the session.</div>'
            "</div></div></main>"
        )
    else:
        by_file: dict[str, list[HunkEvidence]] = {}
        for e in evidence:
            by_file.setdefault(e.attribution.hunk.file_path, []).append(e)

        sections: list[str] = []
        for file_path, hunks in by_file.items():
            hunk_blocks: list[str] = []
            for e in hunks:
                h = e.attribution.hunk
                range_str = f"@@ +{h.new_start},{h.new_count} −{h.base_start},{h.base_count}"

                display_prompts = e.attribution.framing_prompts or e.attribution.prompts
                if display_prompts:
                    prompt_html = "".join(
                        f'<div class="prompt"><span class="src">{html.escape(p.source)}</span>{html.escape(p.text)}</div>'
                        for p in display_prompts
                    )
                else:
                    prompt_html = '<div class="no-prompt">No prompt found in session.</div>'

                chips: list[str] = []
                if e.attribution.edits:
                    tool_counts: dict[str, int] = {}
                    for ev in e.attribution.edits:
                        tool_counts[ev.tool] = tool_counts.get(ev.tool, 0) + 1
                    for tool, n in tool_counts.items():
                        chips.append(f'<span class="chip">{n}× {html.escape(tool)}</span>')
                    if e.retry_count:
                        chips.append(f'<span class="chip retry">{e.retry_count} retries</span>')
                chips_html = (
                    f'<div class="chips">{"".join(chips)}</div>' if chips else ""
                )

                if e.test_runs:
                    test_rows: list[str] = []
                    for t in e.test_runs:
                        klass, glyph = _status_class(t.exit_status)
                        cmd = ""
                        if isinstance(t.input, dict):
                            cmd = str(t.input.get("command") or t.input.get("cmd") or "")
                        out_preview = _truncate(t.output or "", 200)
                        test_rows.append(
                            f'<div class="test">'
                            f'<span class="status {klass}">{glyph}</span>'
                            f'<span class="cmd">{html.escape(_truncate(cmd, 120))}</span>'
                            f'<span class="out">{html.escape(out_preview)}</span>'
                            f"</div>"
                        )
                    tests_html = f'<div class="tests">{"".join(test_rows)}</div>'
                else:
                    tests_html = '<div class="empty">No test run in this prompt.</div>'

                hunk_blocks.append(
                    f'<div class="hunk">'
                    f'<div class="hunk-range">{html.escape(range_str)}</div>'
                    f"{prompt_html}{chips_html}{tests_html}"
                    f"</div>"
                )

            sections.append(
                f'<details class="file" open>'
                f'<summary>{html.escape(file_path)}<span class="count">{len(hunks)} hunk{"s" if len(hunks) != 1 else ""}</span></summary>'
                f'<div class="hunks">{"".join(hunk_blocks)}</div>'
                f"</details>"
            )

        body = f'<main>{"".join(sections)}</main>'

    return (
        "<!DOCTYPE html>\n"
        '<html lang="en"><head><meta charset="utf-8">'
        "<title>Threadline X-Ray</title>"
        f"<style>{_CSS}</style></head><body>"
        '<header>'
        '<h1>Agent X-Ray</h1>'
        '<div class="tagline">Per-hunk evidence from the captured agent session.</div>'
        f'<div class="meta">{meta_line}</div>'
        "</header>"
        f"{body}"
        '<footer>threadline xray · self-contained HTML report</footer>'
        "</body></html>"
    )
