# Shared paths and helpers for statusline.sh and report.sh.

DATA_DIR="${CLAUDE_TRACKER_DATA:-$HOME/.claude/prompt-tracking}"
LOG="$DATA_DIR/prompts.csv"
MONTHLY="$DATA_DIR/prompts-monthly.csv"
LOG_HEADER="time,prompt_id,session,project,model,chars,words,est_tokens,sent,got,pct_5h,pct_7d"
MONTHLY_HEADER="month,prompts,sessions,avg_tokens,median_tokens,max_tokens,big_prompts,avg_sent,max_5h,max_7d"

# Human-readable token counts: 850, 12.3k, 1.2M
fmt() {
  awk -v n="${1:-0}" 'BEGIN {
    if (n >= 1000000) printf "%.1fM", n/1000000
    else if (n >= 1000) printf "%.1fk", n/1000
    else printf "%d", n
  }'
}

# Append a finished prompt's state file to the log. mv is atomic, so when
# status line runs overlap only one of them appends the row.
flush_state() {
  local claimed="$1.flushing.$$"
  mv "$1" "$claimed" 2>/dev/null || return 0
  [ -s "$LOG" ] || echo "$LOG_HEADER" > "$LOG"
  cat "$claimed" >> "$LOG"
  rm -f "$claimed"
}
