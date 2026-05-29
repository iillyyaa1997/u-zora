#!/usr/bin/env bash
#
# uZora end-to-end test harness.
#
# Builds the release binary, bundles it into a throwaway .app, launches it
# in a fully isolated environment (temp HTTP port, temp events dir, temp
# SQLite db, temp config, temp watchdog state), and exercises every
# external surface through real process boundaries:
#
#   - HTTP REST     : /status /alerts /probes /metrics
#   - MCP           : initialize / tools/list / tools/call (JSON-RPC 2.0)
#   - SSE           : /stream connection + live event delivery
#   - JSONL         : event-log file written with correct schema
#   - SQLite        : metrics samples persisted + queryable via REST
#   - Restart       : Watchdog state persists; no duplicate `appeared`
#   - Lifecycle     : graceful shutdown, no orphan process
#
# Determinism: a synthetic always-firing probe is enabled via
# UZORA_E2E_SYNTHETIC_ALERT so assertions don't depend on the host's
# actual disk/thermal/battery state.
#
# Exit code 0 = all passed, 1 = one or more failures.
#
# Usage:
#   Tests/e2e/run-e2e.sh            # build + run
#   SKIP_BUILD=1 Tests/e2e/run-e2e.sh   # reuse existing .build/release/uZora
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Locate repo root (this script lives in Tests/e2e/).
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Isolated scratch environment.
# ---------------------------------------------------------------------------
E2E_TMP="$(mktemp -d "${TMPDIR:-/tmp}/uzora-e2e.XXXXXX")"
APP_BUNDLE="$E2E_TMP/uZora.app"
EVENTS_DIR="$E2E_TMP/events"
METRICS_DB="$E2E_TMP/metrics.sqlite"
CONFIG_PATH="$E2E_TMP/config.toml"
WATCHDOG_STATE="$E2E_TMP/watchdog-state.json"
APP_LOG="$E2E_TMP/uzora.log"
# Pick a high, unlikely-to-collide loopback port.
PORT="${UZORA_E2E_PORT:-39937}"
BASE="http://127.0.0.1:$PORT"

APP_PID=""

PASS=0
FAIL=0
FAILED_NAMES=()

# ---------------------------------------------------------------------------
# Pretty output + assertion helpers.
# ---------------------------------------------------------------------------
c_green=$'\033[32m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_rst=$'\033[0m'

pass() { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$c_green" "$c_rst" "$1"; }
fail() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  %sFAIL%s %s\n' "$c_red" "$c_rst" "$1"; [ -n "${2:-}" ] && printf '       %s%s%s\n' "$c_dim" "$2" "$c_rst"; }
section() { printf '\n%s── %s ──%s\n' "$c_dim" "$1" "$c_rst"; }

# assert_contains <name> <haystack> <needle>
assert_contains() {
  if printf '%s' "$2" | grep -q -- "$3"; then pass "$1"; else fail "$1" "expected to contain: $3 | got: $(printf '%s' "$2" | head -c 300)"; fi
}

# assert_json_key <name> <json> <jq-filter> <expected>
assert_jq() {
  local got
  got="$(printf '%s' "$2" | jq -r "$3" 2>/dev/null)"
  if [ "$got" = "$4" ]; then pass "$1"; else fail "$1" "jq '$3' expected '$4' got '$got'"; fi
}

# ---------------------------------------------------------------------------
# Cleanup on any exit.
# ---------------------------------------------------------------------------
cleanup() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null
    # Give it a moment to shut the HTTP listener down.
    for _ in 1 2 3 4 5; do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.3; done
    kill -9 "$APP_PID" 2>/dev/null || true
  fi
  # Belt-and-braces: kill any stray copy bound to our bundle path.
  pkill -f "$APP_BUNDLE" 2>/dev/null || true
  rm -rf "$E2E_TMP"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Preconditions.
# ---------------------------------------------------------------------------
command -v jq   >/dev/null || { echo "FATAL: jq required (brew install jq)"; exit 2; }
command -v curl >/dev/null || { echo "FATAL: curl required"; exit 2; }

# ---------------------------------------------------------------------------
# Build (unless SKIP_BUILD=1).
# ---------------------------------------------------------------------------
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  section "Build release binary"
  if swift build -c release >"$E2E_TMP/build.log" 2>&1; then
    pass "swift build -c release"
  else
    fail "swift build -c release" "see $E2E_TMP/build.log"
    tail -20 "$E2E_TMP/build.log"
    exit 1
  fi
fi

BIN=".build/release/uZora"
RES_BUNDLE=".build/arm64-apple-macosx/release/uZora_uZora.bundle"
[ -x "$BIN" ] || { echo "FATAL: $BIN not found — run without SKIP_BUILD"; exit 2; }

# ---------------------------------------------------------------------------
# Assemble a throwaway .app bundle (LSUIElement needs a real bundle to
# launch cleanly; we launch the inner binary directly for PID control).
# ---------------------------------------------------------------------------
section "Bundle .app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN" "$APP_BUNDLE/Contents/MacOS/uZora"
cp "Sources/uZora/Support/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPLuZor' > "$APP_BUNDLE/Contents/PkgInfo"
if [ -d "$RES_BUNDLE" ]; then
  cp -R "$RES_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
fi
codesign --sign - --deep --force "$APP_BUNDLE" >/dev/null 2>&1 || true
[ -x "$APP_BUNDLE/Contents/MacOS/uZora" ] && pass "bundle assembled" || fail "bundle assembled"

# ---------------------------------------------------------------------------
# Launch helper — starts the app with the isolated env + synthetic alert.
# $1 = synthetic mode (warn|critical|clear)
# ---------------------------------------------------------------------------
launch_app() {
  local mode="$1"
  UZORA_HTTP_PORT="$PORT" \
  UZORA_EVENTS_DIR="$EVENTS_DIR" \
  UZORA_METRICS_PATH="$METRICS_DB" \
  UZORA_CONFIG_PATH="$CONFIG_PATH" \
  UZORA_WATCHDOG_STATE_PATH="$WATCHDOG_STATE" \
  UZORA_E2E_SYNTHETIC_ALERT="$mode" \
    "$APP_BUNDLE/Contents/MacOS/uZora" >>"$APP_LOG" 2>&1 &
  APP_PID=$!
}

# wait_for_http — poll /status until ready or timeout.
wait_for_http() {
  local tries=0
  while [ $tries -lt 50 ]; do
    if curl -fsS --max-time 1 "$BASE/status" >/dev/null 2>&1; then return 0; fi
    # Bail early if the process died.
    kill -0 "$APP_PID" 2>/dev/null || return 1
    sleep 0.2; tries=$((tries+1))
  done
  return 1
}

# ===========================================================================
# Run 1 — synthetic warn alert.
# ===========================================================================
section "Launch (synthetic=warn)"
launch_app warn
if wait_for_http; then pass "HTTP server reachable"; else fail "HTTP server reachable" "see $APP_LOG"; tail -20 "$APP_LOG"; exit 1; fi

section "REST /status"
STATUS="$(curl -fsS --max-time 3 "$BASE/status")"
assert_jq   "/status status=ok"            "$STATUS" '.status' 'ok'
assert_jq   "/status power_state present"  "$STATUS" '.power_state | length > 0' 'true'
# 10 real probes + 1 synthetic = 11 registered.
assert_jq   "/status probes_registered=11" "$STATUS" '.probes_registered' '11'

section "REST /probes"
PROBES="$(curl -fsS --max-time 3 "$BASE/probes")"
assert_jq   "/probes has 11 entries"       "$PROBES" '.probes | length' '11'
assert_contains "/probes includes disk"    "$PROBES" '"disk"'
assert_contains "/probes includes synthetic" "$PROBES" '"synthetic"'

section "REST /alerts (synthetic warn must be firing)"
# Give the 2s synthetic poll a couple cycles.
sleep 3
ALERTS="$(curl -fsS --max-time 3 "$BASE/alerts")"
assert_jq   "/alerts has synthetic alert"  "$ALERTS" '[.alerts[] | select(.probe=="synthetic")] | length' '1'
assert_jq   "/alerts synthetic severity=warn" "$ALERTS" '.alerts[] | select(.probe=="synthetic") | .severity' 'warn'

section "REST /alerts?severity filter"
CRIT_ONLY="$(curl -fsS --max-time 3 "$BASE/alerts?severity=critical")"
assert_jq   "?severity=critical excludes warn synthetic" "$CRIT_ONLY" '[.alerts[] | select(.probe=="synthetic")] | length' '0'

section "MCP JSON-RPC"
MCP_INIT="$(curl -fsS --max-time 3 -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}' "$BASE/mcp")"
assert_jq   "initialize jsonrpc=2.0"       "$MCP_INIT" '.jsonrpc' '2.0'
assert_jq   "initialize protocolVersion"   "$MCP_INIT" '.result.protocolVersion | length > 0' 'true'
assert_jq   "initialize serverInfo.name"   "$MCP_INIT" '.result.serverInfo.name' 'uzora'

MCP_TOOLS="$(curl -fsS --max-time 3 -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' "$BASE/mcp")"
assert_jq   "tools/list has 5 tools"       "$MCP_TOOLS" '.result.tools | length' '5'
assert_contains "tools/list has uzora_status"     "$MCP_TOOLS" 'uzora_status'
assert_contains "tools/list has uzora_list_alerts" "$MCP_TOOLS" 'uzora_list_alerts'

MCP_CALL="$(curl -fsS --max-time 3 -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"uzora_list_alerts","arguments":{}}}' "$BASE/mcp")"
assert_jq   "tools/call not error"         "$MCP_CALL" '.result.isError' 'false'
assert_contains "tools/call surfaces synthetic"   "$MCP_CALL" 'synthetic'

section "SSE /stream"
# Connect for ~2s; expect at least the initial "connected" frame.
SSE_OUT="$(curl -fsS --max-time 2 "$BASE/stream" 2>/dev/null || true)"
assert_contains "/stream emits data frame" "$SSE_OUT" 'data:'

section "JSONL event log"
sleep 1
JSONL_FILE="$(ls "$EVENTS_DIR"/events-*.jsonl 2>/dev/null | head -1)"
if [ -n "$JSONL_FILE" ] && [ -s "$JSONL_FILE" ]; then
  pass "JSONL file created + non-empty"
  LAST_SYNTH="$(grep '"synthetic"' "$JSONL_FILE" | tail -1)"
  assert_contains "JSONL has synthetic appeared" "$LAST_SYNTH" '"kind":"appeared"'
  # Schema parity: each line is valid JSON with a kind field.
  if tail -5 "$JSONL_FILE" | jq -e '.kind' >/dev/null 2>&1; then
    pass "JSONL lines are valid JSON with kind"
  else
    fail "JSONL lines are valid JSON with kind"
  fi
else
  fail "JSONL file created + non-empty" "no events-*.jsonl in $EVENTS_DIR"
fi

section "SQLite metrics persistence"
sleep 3   # let a few metric harvest ticks land
if [ -f "$METRICS_DB" ]; then
  pass "metrics.sqlite created"
  if command -v sqlite3 >/dev/null; then
    ROWS="$(sqlite3 "$METRICS_DB" 'SELECT COUNT(*) FROM samples;' 2>/dev/null || echo 0)"
    if [ "${ROWS:-0}" -gt 0 ]; then pass "metrics table has rows ($ROWS)"; else fail "metrics table has rows" "0 rows"; fi
  fi
  # REST /metrics returns the synthetic series.
  METRICS="$(curl -fsS --max-time 3 "$BASE/metrics?probe=synthetic")"
  assert_jq "/metrics returns synthetic series" "$METRICS" '.samples | length > 0' 'true'
else
  fail "metrics.sqlite created" "$METRICS_DB missing"
fi

# Snapshot the synthetic alert's first_seen for the restart-idempotency check.
FIRST_SEEN_BEFORE="$(printf '%s' "$ALERTS" | jq -r '.alerts[] | select(.probe=="synthetic") | .first_seen')"

section "Graceful shutdown"
kill "$APP_PID" 2>/dev/null
SHUTDOWN_OK=0
for _ in $(seq 1 20); do
  if ! kill -0 "$APP_PID" 2>/dev/null; then SHUTDOWN_OK=1; break; fi
  sleep 0.3
done
[ "$SHUTDOWN_OK" = "1" ] && pass "process exited on SIGTERM" || fail "process exited on SIGTERM" "still alive after 6s"
# Port must be released.
sleep 1
if curl -fsS --max-time 1 "$BASE/status" >/dev/null 2>&1; then
  fail "port released after shutdown" "still answering"
else
  pass "port released after shutdown"
fi

section "Watchdog state persisted"
if [ -f "$WATCHDOG_STATE" ] && grep -q '"synthetic:e2e"' "$WATCHDOG_STATE"; then
  pass "watchdog-state.json holds synthetic alert"
else
  fail "watchdog-state.json holds synthetic alert" "$(cat "$WATCHDOG_STATE" 2>/dev/null | head -c 200)"
fi

# ===========================================================================
# Run 2 — restart with SAME synthetic warn. Watchdog must NOT re-emit
# `appeared` for the already-known alert (idempotent across restart), yet
# /alerts must still surface it (StateStore seeded from persisted state).
# ===========================================================================
section "Restart (idempotency across process restart)"
# Count JSONL appeared events for synthetic before restart.
APPEARED_BEFORE="$(grep -c '"kind":"appeared".*"synthetic"\|"synthetic".*"kind":"appeared"' "$JSONL_FILE" 2>/dev/null || echo 0)"
launch_app warn
if wait_for_http; then pass "HTTP server reachable (run 2)"; else fail "HTTP server reachable (run 2)"; fi
sleep 4

ALERTS2="$(curl -fsS --max-time 3 "$BASE/alerts")"
assert_jq "/alerts still shows synthetic after restart" "$ALERTS2" '[.alerts[] | select(.probe=="synthetic")] | length' '1'

# first_seen should be the ORIGINAL timestamp (restored from disk), not a new one.
FIRST_SEEN_AFTER="$(printf '%s' "$ALERTS2" | jq -r '.alerts[] | select(.probe=="synthetic") | .first_seen')"
if [ -n "$FIRST_SEEN_BEFORE" ] && [ "$FIRST_SEEN_BEFORE" = "$FIRST_SEEN_AFTER" ]; then
  pass "synthetic first_seen preserved across restart ($FIRST_SEEN_AFTER)"
else
  fail "synthetic first_seen preserved across restart" "before=$FIRST_SEEN_BEFORE after=$FIRST_SEEN_AFTER"
fi

APPEARED_AFTER="$(grep -c '"kind":"appeared".*"synthetic"\|"synthetic".*"kind":"appeared"' "$JSONL_FILE" 2>/dev/null || echo 0)"
if [ "$APPEARED_AFTER" = "$APPEARED_BEFORE" ]; then
  pass "no duplicate appeared event on restart (count stayed $APPEARED_AFTER)"
else
  fail "no duplicate appeared event on restart" "before=$APPEARED_BEFORE after=$APPEARED_AFTER"
fi

# ===========================================================================
# Run 3 — restart with synthetic=clear. The previously-firing alert must
# now emit a `cleared` event and disappear from /alerts.
# ===========================================================================
section "Cleared transition across restart"
kill "$APP_PID" 2>/dev/null
for _ in $(seq 1 20); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.3; done
launch_app clear
if wait_for_http; then pass "HTTP server reachable (run 3)"; else fail "HTTP server reachable (run 3)"; fi
sleep 4

ALERTS3="$(curl -fsS --max-time 3 "$BASE/alerts")"
assert_jq "/alerts synthetic cleared" "$ALERTS3" '[.alerts[] | select(.probe=="synthetic")] | length' '0'
LAST_SYNTH_EVENT="$(grep '"synthetic' "$JSONL_FILE" | tail -1)"
assert_contains "JSONL records cleared event" "$LAST_SYNTH_EVENT" 'cleared'

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
section "Summary"
TOTAL=$((PASS+FAIL))
printf '\n  %d/%d checks passed' "$PASS" "$TOTAL"
if [ "$FAIL" -gt 0 ]; then
  printf '  —  %s%d failed%s\n' "$c_red" "$FAIL" "$c_rst"
  for n in "${FAILED_NAMES[@]}"; do printf '    %s✗%s %s\n' "$c_red" "$c_rst" "$n"; done
  exit 1
fi
printf '  %s✓ all green%s\n' "$c_green" "$c_rst"
exit 0
