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


def set_window_size(fd: int) -> None:
    try:
        rows, cols = os.get_terminal_size(sys.stdin.fileno())
    except OSError:
        return
    winsize = struct.pack("HHHH", rows, cols, 0, 0)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)


def append_bytes(path: Path, data: bytes) -> None:
    with path.open("ab") as log_file:
        log_file.write(data)
        log_file.flush()


def run_session(shell: str | None = None) -> int:
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

    print(f"Threadline session started: {session_id}")
    print("Exit the shell to stop recording.\n")

    old_tty = termios.tcgetattr(sys.stdin.fileno())

    def resize_handler(signum: int, frame: object) -> None:
        del signum, frame
        set_window_size(master_fd)

    previous_resize_handler = signal.getsignal(signal.SIGWINCH)
    signal.signal(signal.SIGWINCH, resize_handler)
    set_window_size(master_fd)

    status = 0
    try:
        tty.setraw(sys.stdin.fileno())
        while True:
            readable, _, _ = select.select([sys.stdin.fileno(), master_fd], [], [])
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
