from __future__ import annotations

import hashlib
import os
import subprocess
from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class CommandResult:
    ok: bool
    output: str
    error: str = ""


@dataclass(frozen=True)
class Context:
    cwd: str
    tmux_pane: str | None
    pane_text: str
    pane_hash: str
    git_branch: str | None
    git_status: str
    git_diff_stat: str
    warnings: list[str]

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


def run(command: list[str], cwd: str | None = None) -> CommandResult:
    try:
        completed = subprocess.run(
            command,
            cwd=cwd,
            text=True,
            capture_output=True,
            check=False,
        )
    except FileNotFoundError:
        return CommandResult(False, "", f"{command[0]} not found")

    return CommandResult(
        completed.returncode == 0,
        completed.stdout.strip(),
        completed.stderr.strip(),
    )


def collect_context(pane_lines: int = 3000) -> Context:
    cwd = os.getcwd()
    warnings: list[str] = []
    tmux_pane = os.environ.get("TMUX_PANE")

    pane = run(["tmux", "capture-pane", "-pS", f"-{pane_lines}"])
    pane_text = pane.output if pane.ok else ""
    if not pane.ok:
        warnings.append("tmux pane capture unavailable; run inside tmux for best results")

    pane_hash = hashlib.sha256(pane_text.encode("utf-8")).hexdigest()

    branch = run(["git", "branch", "--show-current"], cwd=cwd)
    status = run(["git", "status", "--short"], cwd=cwd)
    diff_stat = run(["git", "diff", "--stat"], cwd=cwd)

    git_branch = branch.output or None
    git_status = status.output if status.ok else ""
    git_diff_stat = diff_stat.output if diff_stat.ok else ""

    if not status.ok:
        warnings.append("git context unavailable; current directory may not be a git repo")

    return Context(
        cwd=cwd,
        tmux_pane=tmux_pane,
        pane_text=pane_text,
        pane_hash=pane_hash,
        git_branch=git_branch,
        git_status=git_status,
        git_diff_stat=git_diff_stat,
        warnings=warnings,
    )

