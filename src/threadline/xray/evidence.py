"""Per-hunk evidence: nearest test run, retry count, failure flag.

Given the attributions from ``mapper.attribute`` plus the full event stream,
this assembles the human-facing facts that turn a diff into something a
reviewer can trust in seconds.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from .events import Event, ToolCall
from .mapper import HunkAttribution

TEST_COMMAND_HINTS = (
    "pytest",
    "npm test",
    "npm run test",
    "yarn test",
    "go test",
    "cargo test",
    "rspec",
    "jest",
    "vitest",
    "mocha",
    "phpunit",
    "tox",
    "ctest",
    "bun test",
)

BASH_TOOLS = {"Bash", "exec_command"}


def _looks_like_test(call: ToolCall) -> bool:
    if call.tool not in BASH_TOOLS:
        return False
    cmd = ""
    if isinstance(call.input, dict):
        cmd = str(call.input.get("command") or call.input.get("cmd") or "")
    return any(hint in cmd for hint in TEST_COMMAND_HINTS)


@dataclass
class HunkEvidence:
    attribution: HunkAttribution
    test_runs: list[ToolCall] = field(default_factory=list)
    retry_count: int = 0
    has_test_failure: bool = False


def assemble(
    events: list[Event],
    attributions: list[HunkAttribution],
) -> list[HunkEvidence]:
    """Attach test runs, retry counts, and failure flags to each attribution."""
    all_calls = [e for e in events if isinstance(e, ToolCall)]

    by_prompt: dict[str, list[ToolCall]] = {}
    for call in all_calls:
        if call.prompt_id:
            by_prompt.setdefault(call.prompt_id, []).append(call)

    result: list[HunkEvidence] = []
    for attr in attributions:
        prompt_ids = {p.id for p in attr.prompts}
        seen_test_ids: set[str] = set()
        relevant_tests: list[ToolCall] = []
        for pid in prompt_ids:
            for call in by_prompt.get(pid, []):
                if _looks_like_test(call) and call.id not in seen_test_ids:
                    relevant_tests.append(call)
                    seen_test_ids.add(call.id)
        # Order test runs by timestamp so the report reads chronologically.
        relevant_tests.sort(key=lambda c: c.timestamp)

        # Retry count = how many edit calls hit this file beyond the first one
        # in this attribution's prompt cluster. >0 means the agent had to redo work.
        retry_count = max(0, len(attr.edits) - 1)

        has_failure = any(
            (t.exit_status is not None and t.exit_status != 0) for t in relevant_tests
        )

        result.append(
            HunkEvidence(
                attribution=attr,
                test_runs=relevant_tests,
                retry_count=retry_count,
                has_test_failure=has_failure,
            )
        )

    return result
