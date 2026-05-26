#!/usr/bin/env bash
# uninstall.sh — remove notch-agent hooks from Claude Code + Codex

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required" >&2
    exit 1
fi

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CODEX_HOOKS="$HOME/.codex/hooks.json"
INSTALL_TARGET="$HOME/.config/notch-agent/notch-bridge.sh"

strip_from() {
    local file="$1"
    [ ! -f "$file" ] && return 0
    cp "$file" "${file}.bak.$(date +%s)"
    local tmp
    tmp="$(mktemp)"
    jq '
      def stripNotch(arr):
        (arr // []) | map(
          .hooks |= map(select((.command // "") | contains("notch-bridge.sh") | not))
        ) | map(select((.hooks | length) > 0));

      walk(
        if type == "object" and (.hooks | type) == "array" then
          .hooks |= map(select((.command // "") | contains("notch-bridge.sh") | not))
        else . end
      ) |
      (if .hooks? then
        .hooks |= (
          with_entries(.value = stripNotch(.value))
          | with_entries(select(.value | length > 0))
        )
      else . end)
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
    echo "✓ Cleaned $file"
}

strip_from "$CLAUDE_SETTINGS"

# For ~/.codex/hooks.json the events are at top level, not under .hooks
if [ -f "$CODEX_HOOKS" ]; then
    cp "$CODEX_HOOKS" "${CODEX_HOOKS}.bak.$(date +%s)"
    tmp="$(mktemp)"
    jq '
      def stripNotch(arr):
        (arr // []) | map(
          .hooks |= map(select((.command // "") | contains("notch-bridge.sh") | not))
        ) | map(select((.hooks | length) > 0));

      with_entries(.value = stripNotch(.value))
      | with_entries(select(.value | length > 0))
    ' "$CODEX_HOOKS" > "$tmp"
    mv "$tmp" "$CODEX_HOOKS"
    echo "✓ Cleaned $CODEX_HOOKS"
fi

# Remove the installed bridge copy
if [ -f "$INSTALL_TARGET" ]; then
    rm "$INSTALL_TARGET"
    rmdir "$(dirname "$INSTALL_TARGET")" 2>/dev/null || true
    echo "✓ Removed $INSTALL_TARGET"
fi

echo ""
echo "Done. NotchAgent hooks removed. Backups left next to each modified file."
