#!/usr/bin/env bash
# install.sh — wire notch-bridge.sh into Claude Code + Codex configs
#
# Idempotent. Run again to refresh. Use uninstall.sh to remove.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="$SCRIPT_DIR/notch-bridge.sh"
INSTALL_TARGET="$HOME/.config/notch-agent/notch-bridge.sh"

# --- Pre-flight ----------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required. Install with: brew install jq" >&2
    exit 1
fi

if [ ! -f "$BRIDGE" ]; then
    echo "error: bridge script not found at $BRIDGE" >&2
    exit 1
fi

# Copy the bridge to a stable location so user configs don't break if
# this repo moves. Using ~/.config/notch-agent/ keeps it out of $PATH
# (it's not meant to be invoked manually) while remaining easy to find.
mkdir -p "$(dirname "$INSTALL_TARGET")"
cp "$BRIDGE" "$INSTALL_TARGET"
chmod +x "$INSTALL_TARGET"
echo "✓ Installed bridge to $INSTALL_TARGET"

# --- Claude Code ---------------------------------------------------------

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
[ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"

# Backup once per install run
cp "$CLAUDE_SETTINGS" "${CLAUDE_SETTINGS}.bak.$(date +%s)"

# Build the hook entries we want to merge in. We use a fixed marker
# (`notch-bridge.sh`) on each command so reinstalls overwrite cleanly.
#
# Event → bridge name → boringNotch status:
#   SessionStart      session_start      → working
#   UserPromptSubmit  user_prompt        → working (clears temp-done on a new prompt)
#   PreToolUse        pre_tool           → working (interactive tools → need-input)
#   PostToolUse       post_tool          → working
#   PermissionRequest permission_request → need-input (the deterministic permission signal)
#   Notification      waiting            → need-input (e.g. 60s idle prompt)
#   Stop              stop               → temp-done
#   SubagentStop      subagent_stop      → ignored
#   SessionEnd        session_end        → removed
#
# All entries are fire-and-forget (E1): permission_request only *observes*.
# Claude Code still shows its own terminal permission prompt because the hook
# exits 0 with no stdout. (Phase E2 adds an opt-in blocking variant.)
TMP="$(mktemp)"
jq --arg bridge "$INSTALL_TARGET" '
  # Helper: a single hook entry that calls our bridge with a given event name
  def entry(name): {
    hooks: [{
      type: "command",
      command: ($bridge + " " + name)
    }]
  };

  # Strip any existing notch-agent hooks before adding fresh ones
  def stripNotch(arr):
    (arr // []) | map(
      .hooks |= map(select((.command // "") | contains("notch-bridge.sh") | not))
    ) | map(select((.hooks | length) > 0));

  .hooks //= {}
  | .hooks.SessionStart      = (stripNotch(.hooks.SessionStart)      + [entry("session_start")])
  | .hooks.UserPromptSubmit  = (stripNotch(.hooks.UserPromptSubmit)  + [entry("user_prompt")])
  | .hooks.PreToolUse        = (stripNotch(.hooks.PreToolUse)        + [entry("pre_tool")])
  | .hooks.PostToolUse       = (stripNotch(.hooks.PostToolUse)       + [entry("post_tool")])
  | .hooks.PermissionRequest = (stripNotch(.hooks.PermissionRequest) + [entry("permission_request")])
  | .hooks.Notification      = (stripNotch(.hooks.Notification)      + [entry("waiting")])
  | .hooks.Stop              = (stripNotch(.hooks.Stop)              + [entry("stop")])
  | .hooks.SubagentStop      = (stripNotch(.hooks.SubagentStop)      + [entry("subagent_stop")])
  | .hooks.SessionEnd        = (stripNotch(.hooks.SessionEnd)        + [entry("session_end")])
' "$CLAUDE_SETTINGS" > "$TMP"
mv "$TMP" "$CLAUDE_SETTINGS"
echo "✓ Updated $CLAUDE_SETTINGS"

# --- Codex ---------------------------------------------------------------
# Codex has no PermissionRequest hook; only wire the events it supports.

CODEX_HOOKS="$HOME/.codex/hooks.json"
mkdir -p "$(dirname "$CODEX_HOOKS")"
[ -f "$CODEX_HOOKS" ] || echo '{}' > "$CODEX_HOOKS"

cp "$CODEX_HOOKS" "${CODEX_HOOKS}.bak.$(date +%s)"

TMP="$(mktemp)"
jq --arg bridge "$INSTALL_TARGET" '
  def entry(name): {
    hooks: [{
      type: "command",
      command: ($bridge + " " + name)
    }]
  };

  def stripNotch(arr):
    (arr // []) | map(
      .hooks |= map(select((.command // "") | contains("notch-bridge.sh") | not))
    ) | map(select((.hooks | length) > 0));

  .SessionStart  = (stripNotch(.SessionStart)  + [entry("session_start")])
  | .PreToolUse  = (stripNotch(.PreToolUse)    + [entry("pre_tool")])
  | .PostToolUse = (stripNotch(.PostToolUse)   + [entry("post_tool")])
  | .Stop        = (stripNotch(.Stop)          + [entry("stop")])
  | .SubagentStop= (stripNotch(.SubagentStop)  + [entry("subagent_stop")])
' "$CODEX_HOOKS" > "$TMP"
mv "$TMP" "$CODEX_HOOKS"
echo "✓ Updated $CODEX_HOOKS"

# --- Done ----------------------------------------------------------------

echo ""
echo "Done. Open a NEW terminal and run \`claude\` or \`codex\` to test"
echo "(hooks are read at session start, so existing sessions won't pick this up)."
echo ""
echo "To smoke-test the local server directly:"
echo "  curl -X POST http://127.0.0.1:7878/event -H 'Content-Type: application/json' \\"
echo "    -d '{\"event\":\"permission_request\",\"source\":\"claude\",\"pid\":1,\"cwd\":\"/tmp\",\"ts\":0,\"payload\":{\"tool_name\":\"Bash\"}}'"
