from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import time

from .cache import read_state, read_summary, write_cache
from .collect import collect_context
from .summarize import render_compact_summary, render_summary

TOP_PANE_OPTION = "@threadline_top_pane"
STATUS_ACTIVE_OPTION = "@threadline_status_active"
STATUS_TARGET_OPTION = "@threadline_target_pane"
STATUS_PREV_OPTIONS = {
    "status": "@threadline_prev_status",
    "status-position": "@threadline_prev_status_position",
    "status-interval": "@threadline_prev_status_interval",
}
STATUS_PREV_FORMAT_PREFIX = "@threadline_prev_status_format_"
STATUS_LINES = 5
BORDER_ACTIVE_OPTION = "@threadline_border_active"
BORDER_TARGET_OPTION = "@threadline_border_target_pane"
BORDER_PREV_OPTIONS = {
    "pane-border-status": "@threadline_prev_pane_border_status",
    "pane-border-format": "@threadline_prev_pane_border_format",
}


def build_and_cache_summary(compact: bool = False) -> str:
    context = collect_context()
    width = shutil.get_terminal_size((100, 20)).columns
    summary = render_compact_summary(context, width=width) if compact else render_summary(context)
    state = context.to_dict()
    state["summary"] = summary
    state["updated_at"] = time.time()
    write_cache(summary, state)
    return summary


def summarize_command() -> int:
    print(build_and_cache_summary())
    return 0


def should_refresh(max_age: int) -> bool:
    state = read_state()
    if not state:
        return True

    updated_at = state.get("updated_at")
    if not isinstance(updated_at, int | float):
        return True

    return time.time() - updated_at > max_age


def wait_for_key() -> None:
    print("\nPress any key to close.", end="", flush=True)
    os.system("stty -echo -icanon min 1 time 0")
    try:
        sys.stdin.read(1)
    finally:
        os.system("stty sane")
        print()


def wait_for_key_compact() -> None:
    print("Press any key to close.", end="", flush=True)
    os.system("stty -echo -icanon min 1 time 0")
    try:
        sys.stdin.read(1)
    finally:
        os.system("stty sane")


def compact_summary_lines() -> list[str]:
    return build_and_cache_summary(compact=True).splitlines()


def status_line_command(index: int) -> int:
    lines = compact_summary_lines()
    if 0 <= index < len(lines):
        print(lines[index])
    return 0


def border_line_command() -> int:
    lines = compact_summary_lines()
    print(lines[1] if len(lines) > 1 else "Threadline")
    return 0


def show_command(max_age: int, wait: bool, compact: bool) -> int:
    summary = build_and_cache_summary(compact=compact) if compact or should_refresh(max_age) else read_summary()
    if not summary:
        summary = build_and_cache_summary(compact=compact)

    print(summary)

    if wait and sys.stdin.isatty():
        wait_for_key()

    return 0


def watch_command(interval: int, compact: bool) -> int:
    try:
        while True:
            print("\033[2J\033[H", end="")
            print(build_and_cache_summary(compact=compact))
            if not compact:
                print(f"\nRefreshing every {interval}s. Press Ctrl-C to exit.")
            time.sleep(interval)
    except KeyboardInterrupt:
        return 0


def run_tmux(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["tmux", *args],
        text=True,
        capture_output=True,
        check=False,
    )


def in_tmux() -> bool:
    return bool(os.environ.get("TMUX") and os.environ.get("TMUX_PANE"))


def tmux_pane_exists(pane_id: str) -> bool:
    if not pane_id:
        return False
    completed = run_tmux(["display-message", "-p", "-t", pane_id, "#{pane_id}"])
    return completed.returncode == 0 and completed.stdout.strip() == pane_id


def pane_process_command(pid: str) -> str:
    completed = subprocess.run(
        ["ps", "-p", pid, "-o", "command="],
        text=True,
        capture_output=True,
        check=False,
    )
    return completed.stdout.strip()


def kill_stale_watch_panes() -> int:
    completed = run_tmux(["list-panes", "-a", "-F", "#{pane_id} #{pane_pid}"])
    if completed.returncode != 0:
        return 0

    killed = 0
    for line in completed.stdout.splitlines():
        parts = line.split(maxsplit=1)
        if len(parts) != 2:
            continue
        pane_id, pid = parts
        command = pane_process_command(pid)
        if "threadline watch --compact" not in command:
            continue
        run_tmux(["kill-pane", "-t", pane_id])
        killed += 1
    return killed


def show_top_command(height: int) -> int:
    target_pane = os.environ.get("TMUX_PANE")
    if not target_pane:
        return show_command(max_age=0, wait=True, compact=False)

    command = (
        f"THREADLINE_TARGET_PANE={target_pane} "
        "threadline show --compact --max-age 0 --no-wait; "
        "threadline wait-key"
    )
    completed = run_tmux(
        [
            "display-popup",
            "-E",
            "-x",
            "0",
            "-y",
            "0",
            "-w",
            "100%",
            "-h",
            str(height),
            command,
        ]
    )
    if completed.returncode != 0:
        print(completed.stderr.strip(), file=sys.stderr)
        return completed.returncode
    return 0


def open_top_pane(height: int, interval: int) -> int:
    target_pane = os.environ.get("TMUX_PANE")
    if not target_pane:
        print("Threadline top must be run inside tmux.", file=sys.stderr)
        return 1

    command = (
        f"THREADLINE_TARGET_PANE={target_pane} "
        f"threadline watch --compact --interval {interval}"
    )
    completed = run_tmux(
        [
            "split-window",
            "-v",
            "-b",
            "-l",
            str(height),
            "-d",
            "-P",
            "-F",
            "#{pane_id}",
            command,
        ]
    )
    if completed.returncode != 0:
        print(completed.stderr.strip(), file=sys.stderr)
        return completed.returncode

    top_pane = completed.stdout.strip()
    run_tmux(["set-option", "-gq", TOP_PANE_OPTION, top_pane])
    print(f"Threadline top pane opened for {target_pane}.")
    return 0


def close_top_pane() -> bool:
    completed = run_tmux(["show-option", "-gqv", TOP_PANE_OPTION])
    top_pane = completed.stdout.strip()
    if not tmux_pane_exists(top_pane):
        run_tmux(["set-option", "-guq", TOP_PANE_OPTION])
        return False

    run_tmux(["kill-pane", "-t", top_pane])
    run_tmux(["set-option", "-guq", TOP_PANE_OPTION])
    return True


def tmux_option(name: str) -> str:
    completed = run_tmux(["show-option", "-gqv", name])
    return completed.stdout.rstrip("\n")


def set_tmux_option(name: str, value: str) -> None:
    run_tmux(["set-option", "-gq", name, value])


def unset_tmux_option(name: str) -> None:
    run_tmux(["set-option", "-guq", name])


def status_active() -> bool:
    completed = run_tmux(["show-option", "-gqv", STATUS_ACTIVE_OPTION])
    return completed.stdout.strip() == "1"


def border_active() -> bool:
    completed = run_tmux(["show-option", "-gqv", BORDER_ACTIVE_OPTION])
    return completed.stdout.strip() == "1"


def open_status_top(interval: int) -> int:
    target_pane = os.environ.get("TMUX_PANE")
    if not target_pane:
        print("Threadline toggle must be run inside tmux.", file=sys.stderr)
        return 1

    close_top_pane()
    for option, previous_option in STATUS_PREV_OPTIONS.items():
        set_tmux_option(previous_option, tmux_option(option))
    for index in range(STATUS_LINES):
        set_tmux_option(f"{STATUS_PREV_FORMAT_PREFIX}{index}", tmux_option(f"status-format[{index}]"))

    set_tmux_option(STATUS_TARGET_OPTION, target_pane)
    set_tmux_option(STATUS_ACTIVE_OPTION, "1")
    set_tmux_option("status", str(STATUS_LINES))
    set_tmux_option("status-position", "top")
    set_tmux_option("status-interval", str(interval))

    for index in range(STATUS_LINES):
        set_tmux_option(
            f"status-format[{index}]",
            f"#(THREADLINE_TARGET_PANE=#{{@threadline_target_pane}} threadline status-line {index})",
        )

    run_tmux(["refresh-client", "-S"])
    return 0


def close_status_top() -> bool:
    if not status_active():
        return False

    for option, previous_option in STATUS_PREV_OPTIONS.items():
        previous = tmux_option(previous_option)
        if previous:
            set_tmux_option(option, previous)
        unset_tmux_option(previous_option)

    for index in range(STATUS_LINES):
        previous = tmux_option(f"{STATUS_PREV_FORMAT_PREFIX}{index}")
        if previous:
            set_tmux_option(f"status-format[{index}]", previous)
        else:
            unset_tmux_option(f"status-format[{index}]")
        unset_tmux_option(f"{STATUS_PREV_FORMAT_PREFIX}{index}")

    unset_tmux_option(STATUS_TARGET_OPTION)
    unset_tmux_option(STATUS_ACTIVE_OPTION)
    run_tmux(["refresh-client", "-S"])
    return True


def open_border_top() -> int:
    target_pane = os.environ.get("TMUX_PANE")
    if not target_pane:
        print("Threadline toggle must be run inside tmux.", file=sys.stderr)
        return 1

    close_status_top()
    close_top_pane()

    for option, previous_option in BORDER_PREV_OPTIONS.items():
        set_tmux_option(previous_option, tmux_option(option))

    set_tmux_option(BORDER_TARGET_OPTION, target_pane)
    set_tmux_option(BORDER_ACTIVE_OPTION, "1")
    set_tmux_option("pane-border-status", "top")
    set_tmux_option(
        "pane-border-format",
        "#[align=left]#(THREADLINE_TARGET_PANE=#{@threadline_border_target_pane} threadline border-line)",
    )
    run_tmux(["refresh-client", "-S"])
    return 0


def close_border_top() -> bool:
    if not border_active():
        return False

    for option, previous_option in BORDER_PREV_OPTIONS.items():
        previous = tmux_option(previous_option)
        if previous:
            set_tmux_option(option, previous)
        else:
            unset_tmux_option(option)
        unset_tmux_option(previous_option)

    unset_tmux_option(BORDER_TARGET_OPTION)
    unset_tmux_option(BORDER_ACTIVE_OPTION)
    run_tmux(["refresh-client", "-S"])
    return True


def reset_command() -> int:
    killed = kill_stale_watch_panes()
    restored = close_status_top()
    border_restored = close_border_top()
    close_top_pane()

    for option in [
        TOP_PANE_OPTION,
        STATUS_ACTIVE_OPTION,
        STATUS_TARGET_OPTION,
        BORDER_ACTIVE_OPTION,
        BORDER_TARGET_OPTION,
    ]:
        unset_tmux_option(option)
    for previous_option in STATUS_PREV_OPTIONS.values():
        unset_tmux_option(previous_option)
    for previous_option in BORDER_PREV_OPTIONS.values():
        unset_tmux_option(previous_option)
    for index in range(STATUS_LINES):
        previous_key = f"{STATUS_PREV_FORMAT_PREFIX}{index}"
        previous = tmux_option(previous_key)
        current = tmux_option(f"status-format[{index}]")
        if previous:
            set_tmux_option(f"status-format[{index}]", previous)
        elif "threadline status-line" in current:
            unset_tmux_option(f"status-format[{index}]")
        unset_tmux_option(previous_key)

    run_tmux(["refresh-client", "-S"])
    print(f"Threadline reset complete. Killed {killed} stale pane(s).")
    if restored or border_restored:
        print("Restored previous tmux display settings.")
    return 0


def top_command(height: int, interval: int) -> int:
    del height
    del interval
    close_border_top()
    return open_border_top()


def toggle_command(height: int, interval: int) -> int:
    del height
    del interval
    if close_border_top():
        return 0
    return open_border_top()


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="threadline",
        description="Summarize the current terminal work thread.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("summarize", help="Generate a fresh session summary.")

    show_parser = subparsers.add_parser("show", help="Show the cached session summary.")
    show_parser.add_argument(
        "--max-age",
        type=int,
        default=60,
        help="Refresh cached summary when older than this many seconds.",
    )
    show_parser.add_argument(
        "--no-wait",
        action="store_true",
        help="Print and exit without waiting for a keypress.",
    )
    show_parser.add_argument(
        "--compact",
        action="store_true",
        help="Use the compact tmux bar layout.",
    )
    show_parser.add_argument(
        "--plain",
        action="store_true",
        help="Print in the current pane instead of opening a temporary tmux top pane.",
    )
    show_parser.add_argument(
        "--height",
        type=int,
        default=6,
        help="Height of the temporary tmux top pane.",
    )

    subparsers.add_parser("wait-key", help=argparse.SUPPRESS)

    status_line_parser = subparsers.add_parser("status-line", help=argparse.SUPPRESS)
    status_line_parser.add_argument("index", type=int)

    subparsers.add_parser("border-line", help=argparse.SUPPRESS)

    watch_parser = subparsers.add_parser("watch", help="Keep the session summary visible.")
    watch_parser.add_argument(
        "--interval",
        type=int,
        default=30,
        help="Refresh interval in seconds.",
    )
    watch_parser.add_argument(
        "--compact",
        action="store_true",
        help="Use the compact tmux bar layout.",
    )

    top_parser = subparsers.add_parser("top", help="Show Threadline in tmux's top status area.")
    top_parser.add_argument(
        "--height",
        type=int,
        default=5,
        help="Ignored; kept for compatibility.",
    )
    top_parser.add_argument(
        "--interval",
        type=int,
        default=15,
        help="Refresh interval in seconds.",
    )

    toggle_parser = subparsers.add_parser("toggle", help="Toggle Threadline in tmux's top status area.")
    toggle_parser.add_argument(
        "--height",
        type=int,
        default=5,
        help="Ignored; kept for compatibility.",
    )
    toggle_parser.add_argument(
        "--interval",
        type=int,
        default=15,
        help="Refresh interval in seconds.",
    )

    subparsers.add_parser("reset", help="Remove stale Threadline tmux panes and status options.")

    args = parser.parse_args()

    if args.command == "summarize":
        return summarize_command()
    if args.command == "show":
        if in_tmux() and not args.plain and not args.compact and not args.no_wait:
            return show_top_command(height=args.height)
        return show_command(max_age=args.max_age, wait=not args.no_wait, compact=args.compact)
    if args.command == "wait-key":
        wait_for_key_compact()
        return 0
    if args.command == "status-line":
        return status_line_command(index=args.index)
    if args.command == "border-line":
        return border_line_command()
    if args.command == "watch":
        return watch_command(interval=args.interval, compact=args.compact)
    if args.command == "top":
        return top_command(height=args.height, interval=args.interval)
    if args.command == "toggle":
        return toggle_command(height=args.height, interval=args.interval)
    if args.command == "reset":
        return reset_command()

    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
