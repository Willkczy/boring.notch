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
# Most events are fire-and-forget. The exception is `permission_request`
# (Claude Code's PermissionRequest hook): we POST it and BLOCK on the response,
# then translate the app's decision into the stdout JSON Claude Code expects.
# Default-safe: if the app returns "defer" (or is down / times out / sends
# anything unexpected), we print NOTHING and exit 0, so Claude Code falls
# through to its own terminal permission prompt. We never auto-allow on error.

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

# Resolve a STABLE pid for tap-to-focus. $PPID is the transient hook shell —
# gone by the time the user taps the notch row. Walk the process tree up to the
# top-most ancestor whose parent is launchd (pid 1): the GUI app hosting the
# session (Terminal / iTerm / Ghostty, or the desktop Claude app). Activating
# that pid app-side brings the session's window forward.
find_gui_ancestor() {
    local pid="$1" ppid
    while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -z "$ppid" ] && break
        [ "$ppid" -eq 1 ] && break   # parent is launchd → pid is the top GUI app
        pid="$ppid"
    done
    echo "${pid:-0}"
}
HOST_PID=$(find_gui_ancestor "${PPID:-0}")

# tmux: the pane's process tree leads up to the (GUI-less) tmux server, not the
# terminal showing it — so the walk above lands on tmux and focus fails. Ask
# tmux which client (terminal) is attached to this pane's session and walk up
# from the CLIENT pid instead, which reaches the real terminal app (Ghostty /
# iTerm / …). A detached session has no client → leave HOST_PID as-is.
if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    _sess=$(tmux display-message -p '#{session_name}' 2>/dev/null)
    _cpid=$(tmux list-clients ${_sess:+-t "$_sess"} -F '#{client_pid}' 2>/dev/null | head -1)
    if [ -n "$_cpid" ]; then
        _gui=$(find_gui_ancestor "$_cpid")
        [ -n "$_gui" ] && [ "$_gui" -gt 1 ] && HOST_PID="$_gui"
    fi
fi

[ -z "$HOST_PID" ] && HOST_PID=0

# Build envelope. We use jq if available for safe escaping; otherwise
# fall back to a minimal manual build that escapes the cwd's quotes.
if command -v jq >/dev/null 2>&1; then
    ENVELOPE=$(jq -cn \
        --arg event "$EVENT" \
        --arg source "$SOURCE" \
        --arg session_id "$SESSION_ID" \
        --argjson pid "$PID" \
        --argjson host_pid "$HOST_PID" \
        --arg cwd "$CWD" \
        --argjson ts "$TS" \
        --argjson payload "$PAYLOAD" \
        '{event:$event, source:$source, session_id:$session_id, pid:$pid, host_pid:$host_pid, cwd:$cwd, ts:$ts, payload:$payload}')
else
    # Crude but workable fallback. jq is strongly recommended.
    CWD_ESC=${CWD//\"/\\\"}
    ENVELOPE="{\"event\":\"$EVENT\",\"source\":\"$SOURCE\",\"session_id\":\"$SESSION_ID\",\"pid\":$PID,\"host_pid\":$HOST_PID,\"cwd\":\"$CWD_ESC\",\"ts\":$TS,\"payload\":$PAYLOAD}"
fi

if [ "$EVENT" = "permission_request" ]; then
    # Blocking: wait for the app's Allow/Deny/defer, then emit Claude Code's
    # PermissionRequest decision JSON on stdout. DECISION_TIMEOUT must exceed
    # the app's own decision timeout (default 120s) so the app responds first;
    # if the app is down, curl returns immediately (connection refused).
    DECISION_TIMEOUT="${NOTCH_AGENT_DECISION_TIMEOUT:-125}"
    RESP=$(curl -s --max-time "$DECISION_TIMEOUT" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "$ENVELOPE" \
        "$ENDPOINT" 2>/dev/null || true)

    BEHAVIOR=""
    if command -v jq >/dev/null 2>&1; then
        BEHAVIOR=$(printf '%s' "$RESP" | jq -r '.behavior // empty' 2>/dev/null || true)
    else
        case "$RESP" in
            *'"behavior":"allow"'*) BEHAVIOR="allow" ;;
            *'"behavior":"deny"'*)  BEHAVIOR="deny" ;;
        esac
    fi

    case "$BEHAVIOR" in
        allow)
            printf '%s' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
            ;;
        deny)
            printf '%s' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}'
            ;;
        *)
            # defer / empty / app down / timeout / unexpected → make no decision.
            : ;;
    esac
    exit 0
fi

curl -s -o /dev/null \
    --max-time "$TIMEOUT" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$ENVELOPE" \
    "$ENDPOINT" 2>/dev/null || true

# Always succeed. Hook failure must not interrupt the agent.
exit 0
