#!/usr/bin/env bash
# Deterministic black-box E2E for realtime capture using a simulated Codex process.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${THREADLINE_BIN:-$ROOT/.build/debug/threadline-overlay}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/threadline-e2e-codex.XXXXXX")"
# File-descriptor discovery returns macOS' canonical `/private/var/...` path.
TMP="$(cd "$TMP" && pwd -P)"
STATE="$TMP/state"
SOCKET="$STATE/overlay.sock"
WORKSPACE="$TMP/workspace"
JSONL="$TMP/home/.codex/sessions/2099/01/01/rollout-threadline-e2e.jsonl"
ROW_ID="codex:$JSONL"
DAEMON_PID=""
AGENT_PID=""

cleanup() {
    if [[ -n "$AGENT_PID" ]]; then kill "$AGENT_PID" 2>/dev/null || true; fi
    if [[ -n "$DAEMON_PID" ]]; then kill "$DAEMON_PID" 2>/dev/null || true; fi
    # A separately installed daemon can briefly observe the fixture process.
    "$HOME/.local/bin/threadline-overlay" refresh >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$(dirname "$JSONL")" "$WORKSPACE" "$STATE"

if [[ ! -x "$BIN" || "${THREADLINE_E2E_BUILD:-0}" == "1" ]]; then
    (cd "$ROOT" && swift build)
fi

cat >"$TMP/codex.swift" <<'SWIFT'
import Darwin
import Foundation

guard CommandLine.arguments.count == 2 else { exit(2) }
let fd = open(CommandLine.arguments[1], O_RDWR)
guard fd >= 0 else { exit(3) }
defer { close(fd) }
while true { sleep(1) }
SWIFT
swiftc "$TMP/codex.swift" -o "$TMP/codex"

append_record() {
    printf '%s\n' "$1" >>"$JSONL"
}

append_record "{\"timestamp\":\"2099-01-01T00:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"threadline-e2e\",\"cwd\":\"$WORKSPACE\",\"originator\":\"codex-tui\",\"model\":\"gpt-5\",\"model_context_window\":256000}}"
append_record '{"timestamp":"2099-01-01T00:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"simulate realtime capture"}}'
append_record '{"timestamp":"2099-01-01T00:00:02.000Z","type":"event_msg","payload":{"type":"task_started"}}'
append_record '{"timestamp":"2099-01-01T00:00:03.000Z","type":"event_msg","payload":{"type":"agent_message","message":"THREADLINE_E2E_STARTED"}}'

run_cli() {
    env THREADLINE_OVERLAY_SOCKET="$SOCKET" \
        THREADLINE_OVERLAY_STATE_DIR="$STATE" \
        THREADLINE_LIVE_ONLY=1 \
        THREADLINE_DISABLE_OLLAMA=1 \
        "$BIN" "$@"
}

start_daemon() {
    env THREADLINE_OVERLAY_SOCKET="$SOCKET" \
        THREADLINE_OVERLAY_STATE_DIR="$STATE" \
        THREADLINE_LIVE_ONLY=1 \
        THREADLINE_DISABLE_OLLAMA=1 \
        "$BIN" daemon >"$TMP/daemon.log" 2>&1 &
    DAEMON_PID=$!
    for _ in $(seq 1 100); do
        # Do not call the user-facing CLI for readiness: on a clean machine it
        # may install/spawn a daemon before this isolated test socket is bound.
        if [[ -S "$SOCKET" ]]; then return 0; fi
        if ! kill -0 "$DAEMON_PID" 2>/dev/null; then break; fi
        sleep 0.1
    done
    echo "FAIL: isolated daemon did not start" >&2
    cat "$TMP/daemon.log" >&2
    return 1
}

wait_for_row() {
    local mode="$1"
    local output="$TMP/snapshots.json"
    for _ in $(seq 1 80); do
        run_cli snapshots --json >"$output" 2>/dev/null || true
        if python3 - "$output" "$ROW_ID" "$mode" "${AGENT_PID:-}" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
row_id, mode = sys.argv[2], sys.argv[3]
pid = int(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else None
row = next((r for r in data.get("snapshots", []) if r.get("id") == row_id), None)
if mode == "working":
    ok = row and row.get("livePid") == pid and row.get("workStatus") == "Working"
elif mode == "updated":
    ok = row and row.get("livePid") == pid and "THREADLINE_E2E_UPDATED" in row.get("activityLine", "")
elif mode == "completed-live":
    ok = row and row.get("livePid") == pid and row.get("workStatus") != "Working"
elif mode == "not-live":
    ok = row is None or "livePid" not in row
elif mode == "absent":
    ok = row is None
else:
    ok = False
raise SystemExit(0 if ok else 1)
PY
        then
            return 0
        fi
        run_cli refresh >/dev/null 2>&1 || true
        sleep 0.5
    done
    echo "FAIL: timed out waiting for fixture state '$mode'" >&2
    cat "$output" >&2 || true
    cat "$TMP/daemon.log" >&2 || true
    return 1
}

"$TMP/codex" "$JSONL" &
AGENT_PID=$!
start_daemon

echo "-> waiting for simulated live Codex session"
wait_for_row working

append_record '{"timestamp":"2099-01-01T00:00:04.000Z","type":"event_msg","payload":{"type":"agent_message","message":"THREADLINE_E2E_UPDATED"}}'
echo "-> waiting for transcript hot update"
wait_for_row updated

append_record '{"timestamp":"2099-01-01T00:00:04.500Z","type":"event_msg","payload":{"type":"task_complete"}}'
echo "-> verifying completed live turn is not shown as working"
wait_for_row completed-live

echo "-> stopping simulated process and verifying liveness clears"
kill "$AGENT_PID"
wait "$AGENT_PID" 2>/dev/null || true
AGENT_PID=""
wait_for_row absent

echo "-> verifying daemon restart never restores stale live identity"
"$TMP/codex" "$JSONL" &
AGENT_PID=$!
append_record '{"timestamp":"2099-01-01T00:00:05.000Z","type":"event_msg","payload":{"type":"task_started"}}'
append_record '{"timestamp":"2099-01-01T00:00:06.000Z","type":"event_msg","payload":{"type":"agent_message","message":"THREADLINE_E2E_RESTART_FIXTURE"}}'
wait_for_row working
run_cli quit >/dev/null 2>&1 || kill "$DAEMON_PID" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null || true
DAEMON_PID=""
kill "$AGENT_PID"
wait "$AGENT_PID" 2>/dev/null || true
AGENT_PID=""
start_daemon
wait_for_row not-live
wait_for_row absent

echo "PASS: simulated session was captured, completed cleanly while attached, removed on exit, and not restored as live after restart"
