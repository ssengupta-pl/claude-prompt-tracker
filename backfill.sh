#!/bin/bash
# Seed the prompt log from Claude Code transcripts, for prompts sent before
# tracking started.
#   backfill.sh <transcript.jsonl>...
#   backfill.sh ~/.claude/projects/*/*.jsonl     # every past session
#
# Each row matches what statusline.sh would have logged: prompt size from your
# text, sent/got from the last API response of that prompt. Transcripts don't
# record plan usage, so pct_5h and pct_7d are left blank. Prompts already in the
# log are skipped, so it is safe to re-run.

HERE="$(dirname "$(readlink -f "$0")")"
source "$HERE/lib.sh"

[ $# -gt 0 ] || { echo "usage: $0 <transcript.jsonl>..." >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for transcript in "$@"; do
  jq -rs --arg home "$HOME" '
    # Typed text of a user entry; empty for tool results, reminders and command output
    def prompt_text:
      .message.content
      | if type == "string" then . else ([.[]? | select(.type == "text") | .text] | join("\n")) end
      | if startswith("<") then "" else . end;

    # claude-opus-5-5 -> Opus 5.5, claude-haiku-4-5-20251001 -> Haiku 4.5
    def display_name:
      sub("^claude-"; "") | sub("-[0-9]{8}$"; "") | split("-")
      | (.[0][:1] | ascii_upcase) + .[0][1:] + " " + (.[1:] | join("."));

    [ .[] | select(.isSidechain != true) ]
    | reduce .[] as $e ({cur: null, out: []};
        if $e.type == "user" and ($e.isMeta | not) and $e.promptId != null
           and $e.promptId != .cur.id and ($e | prompt_text | length) > 0 then
          (if .cur then .out += [.cur] else . end)
          | .cur = {time: $e.timestamp, id: $e.promptId, session: $e.sessionId, cwd: $e.cwd,
                    text: ($e | prompt_text), sent: 0, got: 0, model: ""}
        elif $e.type == "assistant" and .cur != null and $e.message.usage != null
             and $e.message.model != "<synthetic>" then
          .cur.sent = ($e.message.usage | .input_tokens + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))
          | .cur.got = $e.message.usage.output_tokens
          | .cur.model = ($e.message.model | display_name)
        else . end)
    | (.out + (if .cur then [.cur] else [] end))[]
    | (.text | length) as $chars
    | [ (.time | sub("\\.[0-9]+Z$"; "Z") | fromdate | strflocaltime("%Y-%m-%dT%H:%M:%S")),
        .id, .session,
        ((.cwd // "") | sub("^" + $home; "~") | gsub(","; ";")),
        (.model | gsub(","; ";")),
        $chars,
        ([.text | splits("\\s+")] | map(select(. != "")) | length),
        (($chars + 3) / 4 | floor),
        .sent, .got, "", "" ]
    | map(tostring) | join(",")
  ' "$transcript" >> "$TMP/new" || echo "skipped (unreadable): $transcript" >&2
done

mkdir -p "$DATA_DIR"
[ -s "$LOG" ] || echo "$LOG_HEADER" > "$LOG"

# Keep only prompts not already logged, then merge and re-sort by time so
# reports and the monthly rollup can rely on chronological order.
awk -F, 'NR == FNR { if (FNR > 1) seen[$2] = 1; next } !($2 in seen) && !dup[$2]++' \
  "$LOG" "$TMP/new" > "$TMP/add"
added=$(wc -l < "$TMP/add" | tr -d ' ')

{ echo "$LOG_HEADER"; { tail -n +2 "$LOG"; cat "$TMP/add"; } | sort -t, -k1,1; } > "$TMP/log"
mv "$TMP/log" "$LOG"

echo "Added $added prompts to $LOG"
