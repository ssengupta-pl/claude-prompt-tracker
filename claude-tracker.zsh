# Claude Code prompt tracking for zsh. Source this from ~/.zshrc.
#   claude        runs Claude Code as usual, then prints a session report on exit,
#                 plus the all-time report every CLAUDE_REPORT_EVERY prompts
#   claude-stats  prints the all-time report

export CLAUDE_REPORT_EVERY=${CLAUDE_REPORT_EVERY:-25}
export CLAUDE_LOG_MAX_ROWS=${CLAUDE_LOG_MAX_ROWS:-5000}
_claude_tracker_dir=${${(%):-%x}:A:h}

claude() {
  local start=$(date +%Y-%m-%dT%H:%M:%S) began=$SECONDS rc
  command claude "$@"
  rc=$?
  "$_claude_tracker_dir/report.sh" exit "$start" $(( SECONDS - began ))
  return $rc
}

alias claude-stats="$_claude_tracker_dir/report.sh all"
