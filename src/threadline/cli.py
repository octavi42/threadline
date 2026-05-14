from __future__ import annotations

import argparse


def summarize() -> int:
    print("Threadline summarize: not implemented yet.")
    return 0


def show() -> int:
    print("Threadline show: not implemented yet.")
    return 0


def watch() -> int:
    print("Threadline watch: not implemented yet.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="threadline",
        description="Summarize the current terminal work thread.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("summarize", help="Generate a fresh session summary.")
    subparsers.add_parser("show", help="Show the cached session summary.")
    subparsers.add_parser("watch", help="Keep the session summary visible.")

    args = parser.parse_args()

    if args.command == "summarize":
        return summarize()
    if args.command == "show":
        return show()
    if args.command == "watch":
        return watch()

    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

