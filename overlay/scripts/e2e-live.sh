#!/usr/bin/env bash
# Black-box E2E: live Cursor inbox should match resolvable cursor-agent sessions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${THREADLINE_BIN:-$HOME/.local/bin/threadline-overlay}"

if [[ ! -x "$BIN" ]]; then
  echo "→ building release binary…"
  (cd "$ROOT" && swift build -c release)
  BIN="$ROOT/.build/release/threadline-overlay"
fi

echo "→ using $BIN"

wait_for_daemon() {
  for _ in $(seq 1 60); do
    if "$BIN" status 2>/dev/null | grep -q '^running pid='; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

"$BIN" quit 2>/dev/null || true
sleep 0.3
"$BIN" show >/dev/null 2>&1 || true
if ! wait_for_daemon; then
  echo "FAIL: daemon did not start"
  exit 1
fi

echo "→ waiting for snapshot scan…"
sleep 10
"$BIN" refresh >/dev/null
sleep 8

JSON="$("$BIN" snapshots --json 2>/dev/null || true)"
if [[ -z "$JSON" || "$JSON" == *'"error"'* ]]; then
  echo "FAIL: snapshots --json returned invalid payload:"
  echo "$JSON"
  exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
printf '%s' "$JSON" >"$TMP"

eval "$(python3 - "$TMP" <<'PY'
import json, subprocess, sys

d = json.load(open(sys.argv[1]))
snapshots = d.get("snapshots", [])
cursor_rows = sum(1 for s in snapshots if s.get("tool") == "Cursor")
cursor_live = sum(1 for s in snapshots if s.get("tool") == "Cursor" and "livePid" in s)
live_resolvable = d.get("liveCursorAgentCount", 0)
hidden = d.get("hiddenCursorHistoryCount", 0)
agents = d.get("agentCount", 0)
show_hist = d.get("showCursorHistorySessions", False)

r = subprocess.run(
    ["pgrep", "-f", "cursor-agent.*index.js agent"],
    capture_output=True, text=True,
)
pgrep = len([x for x in r.stdout.splitlines() if x.strip()])

def sh(v):
    if isinstance(v, bool):
        return "True" if v else "False"
    return str(v)

for k, v in [
    ("LIVE_PROCS", pgrep),
    ("CURSOR_ROWS", cursor_rows),
    ("CURSOR_LIVE_ROWS", cursor_live),
    ("LIVE_RESOLVABLE", live_resolvable),
    ("HIDDEN", hidden),
    ("AGENTS", agents),
    ("SHOW_HIST", sh(show_hist)),
    ("UNMATCHED", max(0, pgrep - live_resolvable)),
]:
    print(f"{k}={v}")
PY
)"

echo ""
echo "=== E2E live Cursor inbox ==="
echo "cursor-agent processes (pgrep):     $LIVE_PROCS"
echo "resolvable live agents (daemon):    $LIVE_RESOLVABLE"
echo "unmatched pgrep (no trusted ws):   $UNMATCHED"
echo "daemon agentCount:                  $AGENTS"
echo "retained Cursor rows in snapshots:  $CURSOR_ROWS"
echo "Cursor rows with livePid:           $CURSOR_LIVE_ROWS"
echo "hiddenCursorHistoryCount:           $HIDDEN"
echo "showCursorHistorySessions:          $SHOW_HIST"
echo "status:                             $("$BIN" status 2>/dev/null || true)"
echo ""

FAIL=0

if [[ "$SHOW_HIST" != "False" ]]; then
  echo "FAIL: expected showCursorHistorySessions=false by default"
  FAIL=1
fi

if [[ "$CURSOR_LIVE_ROWS" != "$LIVE_RESOLVABLE" ]]; then
  echo "FAIL: live Cursor rows ($CURSOR_LIVE_ROWS) != resolvable live agents ($LIVE_RESOLVABLE)"
  FAIL=1
fi

if [[ "$CURSOR_LIVE_ROWS" -gt "$LIVE_PROCS" ]]; then
  echo "FAIL: live rows exceed running Cursor processes"
  FAIL=1
fi

if [[ "$LIVE_RESOLVABLE" -gt 0 && "$HIDDEN" -eq 0 ]]; then
  echo "WARN: resolvable live agents exist but hiddenCursorHistoryCount is 0"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "PASS: live Cursor rows match resolvable running agents"
  exit 0
fi

echo ""
echo "snapshots JSON (first 2k chars):"
head -c 2000 "$TMP"
echo ""
exit 1
