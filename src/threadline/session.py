from __future__ import annotations

import fcntl
import os
import select
import shlex
import signal
import struct
import sys
import termios
import time
import tty
import uuid
from pathlib import Path

from .cache import SESSIONS_DIR, ensure_state_dir, write_active_session
from .collect import collect_context
from .summarize import render_compact_summary


PANEL_HEIGHT = 5
PANEL_REFRESH_SECONDS = 2.0


def terminal_size() -> tuple[int, int]:
    try:
        rows, cols = os.get_terminal_size(sys.stdin.fileno())
    except OSError:
        return 24, 80
    return rows, cols


def set_window_size(fd: int, panel: bool) -> None:
    rows, cols = terminal_size()
    if panel:
        rows = max(5, rows - PANEL_HEIGHT)
    winsize = struct.pack("HHHH", rows, cols, 0, 0)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)


def append_bytes(path: Path, data: bytes) -> None:
    with path.open("ab") as log_file:
        log_file.write(data)
        log_file.flush()


def write_stdout(value: str) -> None:
    os.write(sys.stdout.fileno(), value.encode("utf-8", errors="replace"))


def enter_panel_layout() -> None:
    rows, _ = terminal_size()
    body_top = min(PANEL_HEIGHT + 1, rows)
    write_stdout("\033[?25l")
    write_stdout("\033[2J\033[H")
    write_stdout(f"\033[{body_top};{rows}r")
    write_stdout(f"\033[{body_top};1H")
    write_stdout("\033[?25h")


def leave_panel_layout() -> None:
    rows, _ = terminal_size()
    write_stdout("\033[?25h")
    write_stdout(f"\033[1;{rows}r")
    write_stdout(f"\033[{rows};1H")


def render_panel(session_id: str) -> None:
    rows, cols = terminal_size()
    context = collect_context()
    lines = render_compact_summary(context, width=cols).splitlines()
    body_top = min(PANEL_HEIGHT + 1, rows)

    write_stdout("\0337")
    write_stdout("\033[?25l")
    for index in range(PANEL_HEIGHT):
        line = lines[index] if index < len(lines) else ""
        if index == 0:
            line = f"Threadline session {session_id}"
        line = line[:cols].ljust(cols)
        write_stdout(f"\033[{index + 1};1H\033[2K{line}")
    write_stdout(f"\033[{body_top};1H")
    write_stdout("\033[?25h")
    write_stdout("\0338")


def run_session(shell: str | None = None, panel: bool = True) -> int:
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        print("threadline session must be run from an interactive terminal.", file=sys.stderr)
        return 1

    ensure_state_dir()
    session_id = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
    log_path = SESSIONS_DIR / f"{session_id}.log"
    shell_command = shell or os.environ.get("SHELL") or "/bin/bash"
    argv = shlex.split(shell_command)

    pid, master_fd = os.forkpty()
    if pid == 0:
        os.environ["THREADLINE_SESSION_ID"] = session_id
        os.environ["THREADLINE_SESSION_LOG"] = str(log_path)
        os.environ["THREADLINE_SESSION_ACTIVE"] = "1"
        os.execvp(argv[0], argv)

    session_state = {
        "id": session_id,
        "log_path": str(log_path),
        "shell": shell_command,
        "started_at": time.time(),
        "pid": pid,
        "cwd": os.getcwd(),
    }
    write_active_session(session_state)

    old_tty = termios.tcgetattr(sys.stdin.fileno())

    def resize_handler(signum: int, frame: object) -> None:
        del signum, frame
        if panel:
            enter_panel_layout()
            render_panel(session_id)
        set_window_size(master_fd, panel=panel)

    previous_resize_handler = signal.getsignal(signal.SIGWINCH)
    signal.signal(signal.SIGWINCH, resize_handler)
    set_window_size(master_fd, panel=panel)

    if panel:
        enter_panel_layout()
        render_panel(session_id)
    else:
        print(f"Threadline session started: {session_id}")
        print("Exit the shell to stop recording.\n")

    status = 0
    next_panel_refresh = time.monotonic() + PANEL_REFRESH_SECONDS
    try:
        tty.setraw(sys.stdin.fileno())
        while True:
            timeout = max(0.1, next_panel_refresh - time.monotonic()) if panel else None
            readable, _, _ = select.select([sys.stdin.fileno(), master_fd], [], [], timeout)

            if panel and time.monotonic() >= next_panel_refresh:
                render_panel(session_id)
                next_panel_refresh = time.monotonic() + PANEL_REFRESH_SECONDS

            if sys.stdin.fileno() in readable:
                data = os.read(sys.stdin.fileno(), 4096)
                if not data:
                    break
                os.write(master_fd, data)

            if master_fd in readable:
                try:
                    data = os.read(master_fd, 4096)
                except OSError:
                    break
                if not data:
                    break
                os.write(sys.stdout.fileno(), data)
                append_bytes(log_path, data)
    finally:
        if panel:
            leave_panel_layout()
        termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, old_tty)
        signal.signal(signal.SIGWINCH, previous_resize_handler)
        try:
            _, raw_status = os.waitpid(pid, 0)
            if os.WIFEXITED(raw_status):
                status = os.WEXITSTATUS(raw_status)
        except ChildProcessError:
            pass
        session_state["ended_at"] = time.time()
        session_state["exit_status"] = status
        write_active_session(session_state)

    return status
