#!/bin/bash
# Claude Code status line.
# Line 1: robbyrussell-style prompt (via Oh My Posh if installed, plain fallback otherwise)
# Line 2: prompt size estimate, last-turn tokens, and Pro plan usage limits
# Also keeps the in-progress prompt's numbers in a per-session state file. When
# a new prompt_id appears, the previous prompt is finished and its row is
# appended to the log. report.sh flushes the last prompt when Claude exits.

HERE="$(dirname "$(readlink -f "$0")")"
source "$HERE/lib.sh"

input=$(cat)
OMP_CONFIG="$HERE/ohmyposh/claude.omp.json"

# One jq pass. \x1f as separator keeps empty fields (tabs would collapse them).
IFS=$'\x1f' read -r dir project model transcript ctx_in out five_h week prompt_id session_id < <(
  echo "$input" | jq -r '[
      .workspace.current_dir // .cwd, .workspace.project_dir // .cwd,
      .model.display_name // "", .transcript_path // "",
      .context_window.total_input_tokens // 0, .context_window.total_output_tokens // 0,
      .rate_limits.five_hour.used_percentage // "", .rate_limits.seven_day.used_percentage // "",
      .prompt_id // "", .session_id // ""
    ] | map(tostring) | join("\u001f")')

# --- Line 1 ---------------------------------------------------------------
if command -v oh-my-posh >/dev/null 2>&1 && [ -f "$OMP_CONFIG" ]; then
  echo "$input" | oh-my-posh claude --config "$OMP_CONFIG"
  echo
else
  branch=$(git -C "$dir" branch --show-current 2>/dev/null)
  line=$(printf '\033[32m➜\033[0m  \033[36m%s\033[0m' "$(basename "$dir")")
  [ -n "$branch" ] && line+=$(printf ' \033[34mgit:(\033[31m%s\033[34m)\033[0m' "$branch")
  [ -n "$model" ] && line+=$(printf ' \033[35m%s\033[0m' "$model")
  echo "$line"
fi

# --- Line 2 ---------------------------------------------------------------
# Size of the last typed prompt, estimated at ~4 characters per token. Skips tool
# results, system reminders and slash-command output, which are also stored as
# "user" entries.
chars=0 words=0
if [ -f "$transcript" ]; then
  read -r chars words < <(tail -n 300 "$transcript" | jq -r '
      select(.type == "user" and (.isMeta | not)) | .message.content
      | if type == "string" then .
        else ([.[] | select(.type == "text") | .text] | join("\n")) end
      | select(length > 0 and (startswith("<") | not))
      | "\(length) \([splits("\\s+")] | map(select(. != "")) | length)"' 2>/dev/null | tail -n 1)
fi
chars=${chars:-0} words=${words:-0}
prompt_tokens=$(( (chars + 3) / 4 ))

DIM=$'\033[2m'; RESET=$'\033[0m'
stats=""
[ "$chars" -gt 0 ] && stats="prompt ~$(fmt "$prompt_tokens")"
stats+="${stats:+ ${DIM}│${RESET} }sent $(fmt "$ctx_in") · got $(fmt "$out")"

# Colour plan usage: green under 50%, yellow under 80%, red above
pct() {
  local p
  p=$(printf '%.0f' "$1")
  if [ "$p" -ge 80 ]; then printf '\033[31m%s%%\033[0m' "$p"
  elif [ "$p" -ge 50 ]; then printf '\033[33m%s%%\033[0m' "$p"
  else printf '\033[32m%s%%\033[0m' "$p"; fi
}
limits=""
[ -n "$five_h" ] && limits="5h $(pct "$five_h")"
[ -n "$week" ] && limits+="${limits:+ · }7d $(pct "$week")"
[ -n "$limits" ] && stats+=" ${DIM}│${RESET} $limits"

echo "$stats"

# --- Prompt log -----------------------------------------------------------
[ -n "$prompt_id" ] && [ -n "$session_id" ] || exit 0

mkdir -p "$DATA_DIR/state"
state="$DATA_DIR/state/$session_id"
started=$(date +%Y-%m-%dT%H:%M:%S)
if [ -f "$state" ]; then
  IFS=, read -r prev_time prev_id _ < "$state"
  if [ "$prev_id" = "$prompt_id" ]; then
    started=$prev_time
  else
    flush_state "$state"
  fi
fi

int() { [ -n "$1" ] && printf '%.0f' "$1"; }
# Commas would break the CSV, so swap them out of free-text fields
project=${project/#$HOME/\~}
row="$started,$prompt_id,$session_id,${project//,/;},${model//,/;},$chars,$words,$prompt_tokens,$ctx_in,$out,$(int "$five_h"),$(int "$week")"
echo "$row" > "$state.tmp.$$" && mv "$state.tmp.$$" "$state"
