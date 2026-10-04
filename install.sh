#!/bin/bash
# Wires the tracker into Claude Code and zsh. Safe to re-run.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"
ZSHRC="$HOME/.zshrc"

chmod +x "$REPO/statusline.sh" "$REPO/report.sh"

# 1. Point Claude Code's status line at this repo
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak"
jq --arg cmd "$REPO/statusline.sh" \
  '.statusLine = {type: "command", command: $cmd, padding: 0}' \
  "$SETTINGS.bak" > "$SETTINGS"
echo "✓ Status line set in $SETTINGS (backup: settings.json.bak)"

# 2. Load the claude wrapper and claude-stats in zsh
if grep -q "claude-tracker.zsh" "$ZSHRC" 2>/dev/null; then
  echo "✓ $ZSHRC already loads the tracker"
else
  cat >> "$ZSHRC" <<EOF

# Claude prompt tracker
export CLAUDE_REPORT_EVERY=25      # all-time report every N prompts
export CLAUDE_LOG_MAX_ROWS=5000    # past this, older prompts roll into monthly summaries
source "$REPO/claude-tracker.zsh"
EOF
  echo "✓ Added tracker to $ZSHRC"
fi

echo "Open a new terminal tab (or run: exec zsh) to start using it."
