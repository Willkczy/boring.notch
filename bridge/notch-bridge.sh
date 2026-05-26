#!/usr/bin/env bash
# notch-bridge.sh — forward agent hook events to boringNotch (Agent Monitor)
#
# Usage (from a Claude Code or Codex hook):
#   ~/.config/notch-agent/notch-bridge.sh <event_name>
#
# The hook payload arrives on stdin as JSON. We wrap it in an envelope
# and POST to the boringNotch local server. Failures are silent and
# non-blocking — the agent must NEVER be delayed by us.
#
# NOTE: this E1 version is fire-and-forget for every event (including
# permission_request — the app only observes, it does not decide). Phase E2
# adds a blocking branch for permission_request that reads the app's decision
# and emits Claude Code's PermissionRequest stdout JSON. Until then a
# permission_request still exits 0 with no stdout, so Claude Code falls through
# to its normal terminal permission prompt.

set -u  # don't set -e: we want to fall through errors silently

EVENT="${1:-unknown}"
PORT="${NOTCH_AGENT_PORT:-7878}"
ENDPOINT="http://127.0.0.1:${PORT}/event"
TIMEOUT="${NOTCH_AGENT_TIMEOUT:-1}"

# Detect source from the script's invocation context.
# Claude Code hooks set CLAUDE_* env vars; Codex sets CODEX_*. Fall back
# to "unknown" if neither is present.
if [ -n "${CLAUDE_SESSION_ID:-}${CLAUDE_PROJECT_DIR:-}" ]; then
    SOURCE="claude"
    SESSION_ID="${CLAUDE_SESSION_ID:-}"
elif [ -n "${CODEX_SESSION_ID:-}${CODEX_HOME:-}" ]; then
    SOURCE="codex"
    SESSION_ID="${CODEX_SESSION_ID:-}"
else
    SOURCE="unknown"
    SESSION_ID=""
fi

# Read hook payload from stdin. If stdin is a TTY (no piped input),
# substitute an empty object so the JSON stays valid.
if [ -t 0 ]; then
    PAYLOAD="{}"
else
    PAYLOAD="$(cat)"
    [ -z "$PAYLOAD" ] && PAYLOAD="{}"
fi

TS=$(date +%s)
PID="${PPID:-0}"
CWD="${PWD:-/}"

# Build envelope. We use jq if available for safe escaping; otherwise
# fall back to a minimal manual build that escapes the cwd's quotes.
if command -v jq >/dev/null 2>&1; then
    ENVELOPE=$(jq -cn \
        --arg event "$EVENT" \
        --arg source "$SOURCE" \
        --arg session_id "$SESSION_ID" \
        --argjson pid "$PID" \
        --arg cwd "$CWD" \
        --argjson ts "$TS" \
        --argjson payload "$PAYLOAD" \
        '{event:$event, source:$source, session_id:$session_id, pid:$pid, cwd:$cwd, ts:$ts, payload:$payload}')
else
    # Crude but workable fallback. jq is strongly recommended.
    CWD_ESC=${CWD//\"/\\\"}
    ENVELOPE="{\"event\":\"$EVENT\",\"source\":\"$SOURCE\",\"session_id\":\"$SESSION_ID\",\"pid\":$PID,\"cwd\":\"$CWD_ESC\",\"ts\":$TS,\"payload\":$PAYLOAD}"
fi

curl -s -o /dev/null \
    --max-time "$TIMEOUT" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$ENVELOPE" \
    "$ENDPOINT" 2>/dev/null || true

# Always succeed. Hook failure must not interrupt the agent.
exit 0
