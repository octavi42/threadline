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


def top_command(height: int, interval: int) -> int:
    target_pane = os.environ.get("TMUX_PANE")
    if not target_pane:
        print("Threadline top must be run inside tmux.", file=sys.stderr)
        return 1

    command = (
        f"THREADLINE_TARGET_PANE={target_pane} "
        f"threadline watch --compact --interval {interval}"
    )
    completed = subprocess.run(
        ["tmux", "split-window", "-v", "-b", "-l", str(height), "-d", command],
        check=False,
    )
    if completed.returncode != 0:
        return completed.returncode

    print(f"Threadline top pane opened for {target_pane}.")
    return 0


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

    top_parser = subparsers.add_parser("top", help="Open a fixed Threadline pane above this pane.")
    top_parser.add_argument(
        "--height",
        type=int,
        default=5,
        help="Height of the fixed top pane.",
    )
    top_parser.add_argument(
        "--interval",
        type=int,
        default=15,
        help="Refresh interval in seconds.",
    )

    args = parser.parse_args()

    if args.command == "summarize":
        return summarize_command()
    if args.command == "show":
        return show_command(max_age=args.max_age, wait=not args.no_wait, compact=args.compact)
    if args.command == "watch":
        return watch_command(interval=args.interval, compact=args.compact)
    if args.command == "top":
        return top_command(height=args.height, interval=args.interval)

    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
