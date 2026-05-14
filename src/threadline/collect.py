from __future__ import annotations

import hashlib
import os
import subprocess
from dataclasses import asdict, dataclass
from pathlib import Path

from .cache import read_active_session


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


def read_session_log(max_bytes: int = 200_000) -> tuple[str, str | None]:
    log_path = os.environ.get("THREADLINE_SESSION_LOG")
    if not log_path:
        active = read_active_session()
        if active:
            candidate = active.get("log_path")
            if isinstance(candidate, str):
                log_path = candidate

    if not log_path:
        return "", None

    path = Path(log_path)
    if not path.exists():
        return "", str(path)

    with path.open("rb") as log_file:
        try:
            log_file.seek(max(0, path.stat().st_size - max_bytes))
        except OSError:
            pass
        data = log_file.read()
    return data.decode("utf-8", errors="replace"), str(path)


def collect_context(pane_lines: int = 3000) -> Context:
    cwd = os.getcwd()
    warnings: list[str] = []
    tmux_pane = os.environ.get("THREADLINE_TARGET_PANE") or os.environ.get("TMUX_PANE")

    pane_command = ["tmux", "capture-pane", "-p", "-S", f"-{pane_lines}"]
    if tmux_pane:
        pane_command.extend(["-t", tmux_pane])

    pane = run(pane_command)
    pane_text = pane.output if pane.ok else ""
    if not pane.ok:
        session_text, session_log = read_session_log()
        pane_text = session_text
        if session_log:
            warnings.append(f"using Threadline session log: {session_log}")
        else:
            warnings.append("no tmux pane or Threadline session log available")

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
