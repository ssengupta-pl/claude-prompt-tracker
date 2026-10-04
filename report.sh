#!/bin/bash
# Prompt usage reports from the local log.
#   report.sh exit <start-time> <seconds>   session summary; run by the claude wrapper on exit
#   report.sh all                           all-time summary (claude-stats)

HERE="$(dirname "$(readlink -f "$0")")"
source "$HERE/lib.sh"

EVERY=${CLAUDE_REPORT_EVERY:-25}
MAX_ROWS=${CLAUDE_LOG_MAX_ROWS:-5000}
BIG=${CLAUDE_BIG_PROMPT:-250}
MILESTONE="$DATA_DIR/last-milestone"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Shared awk helper, same output as fmt() in lib.sh
AWK_FMT='function fmt(n) { return n >= 1000000 ? sprintf("%.1fM", n/1000000) : (n >= 1000 ? sprintf("%.1fk", n/1000) : sprintf("%d", n)) }'

# Data rows, one per prompt. A prompt can be logged twice when two Claude
# sessions run at once; keep the last copy.
rows() {
  [ -f "$LOG" ] || return 0
  awk -F, 'NR > 1 { if (!($2 in row)) order[++n] = $2; row[$2] = $0 }
           END { for (i = 1; i <= n; i++) print row[order[i]] }' "$LOG"
}

median() {
  sort -n | awk '{ v[NR] = $1 }
    END { if (NR == 0) print 0
          else if (NR % 2) print v[(NR + 1) / 2]
          else printf "%d\n", (v[NR / 2] + v[NR / 2 + 1]) / 2 }'
}

total_prompts() {
  local raw monthly
  raw=$(rows | wc -l | tr -d ' ')
  monthly=$([ -f "$MONTHLY" ] && awk -F, 'NR > 1 { s += $2 } END { print s + 0 }' "$MONTHLY" || echo 0)
  echo $(( raw + monthly ))
}

# The last prompt of each session never sees a newer prompt_id, so it is
# still sitting in its state file when Claude exits.
flush_all() {
  local s
  for s in "$DATA_DIR"/state/*; do
    [ -f "$s" ] || continue
    case "$s" in *.flushing.*|*.tmp.*) continue ;; esac
    flush_state "$s"
  done
}

# Past MAX_ROWS, roll the oldest whole months into one summary row each.
# The current month is never rolled, so each month is summarised exactly once.
rollup() {
  rows > "$TMP/rows"
  local n months m med
  n=$(wc -l < "$TMP/rows" | tr -d ' ')
  (( n > MAX_ROWS )) || return 0

  months=$(awk -F, -v excess=$(( n - MAX_ROWS )) -v cur="$(date +%Y-%m)" '
      { m = substr($1, 1, 7); if (!(m in cnt)) order[++k] = m; cnt[m]++ }
      END { for (i = 1; i <= k && rolled < excess; i++) {
              if (order[i] == cur) break
              print order[i]; rolled += cnt[order[i]] } }' "$TMP/rows")
  [ -n "$months" ] || return 0

  [ -s "$MONTHLY" ] || echo "$MONTHLY_HEADER" > "$MONTHLY"
  for m in $months; do
    grep "^$m-" "$TMP/rows" > "$TMP/month"
    med=$(cut -d, -f8 "$TMP/month" | median)
    awk -F, -v m="$m" -v med="$med" -v big="$BIG" '
      { n++; sess[$3]; tok += $8; sent += $9
        if ($8 > max) max = $8
        if ($8 > big) b++
        if ($11 > m5) m5 = $11
        if ($12 > m7) m7 = $12 }
      END { for (k in sess) s++
            printf "%s,%d,%d,%d,%d,%d,%d,%d,%d,%d\n", m, n, s, tok / n, med, max, b, sent / n, m5, m7 }' \
      "$TMP/month" >> "$MONTHLY"
  done

  { echo "$LOG_HEADER"; grep -v -E "^($(echo $months | tr ' ' '|'))-" "$TMP/rows"; } > "$TMP/log"
  mv "$TMP/log" "$LOG"
}

session_report() {
  local start=$1 secs=$2 dur
  rows | awk -F, -v s="$start" '$1 >= s' > "$TMP/session"
  [ -s "$TMP/session" ] || return 1

  if (( secs >= 3600 )); then dur="$(( secs / 3600 ))h $(( secs % 3600 / 60 ))m"
  else dur="$(( secs / 60 ))m"; fi

  awk -F, -v dur="$dur" "$AWK_FMT"'
    { n++; tok += $8; sent += $9; got += $10
      if ($8 > max) max = $8
      if ($11 != "") { if (f5 == "") f5 = $11; l5 = $11 }
      if ($12 != "") { if (f7 == "") f7 = $12; l7 = $12 } }
    END {
      print ""
      print "── Claude session ─────────────────────────────"
      printf " Prompts      %-6d   Duration  %s\n", n, dur
      printf " Prompt size  avg ~%s tok   longest ~%s tok\n", fmt(tok / n), fmt(max)
      printf " Context      avg %s sent · %s got per prompt\n", fmt(sent / n), fmt(got / n)
      if (sent > 0) printf " Your text    %.1f%% of what was sent\n", 100 * tok / sent
      if (f5 != "" || f7 != "") {
        u = " Usage       "
        if (f5 != "") u = u sprintf(" 5h %d%% → %d%%", f5, l5)
        if (f7 != "") u = u sprintf("   7d %d%% → %d%%", f7, l7)
        print u
      }
      print "───────────────────────────────────────────────"
    }' "$TMP/session"
}

alltime_report() {
  rows > "$TMP/rows"
  if [ ! -s "$TMP/rows" ] && [ ! -s "$MONTHLY" ]; then
    echo "No prompts logged yet."
    return
  fi
  local med
  med=$(cut -d, -f8 "$TMP/rows" | median)

  awk -F, -v med="$med" -v every="$EVERY" -v big="$BIG" -v monthly="$MONTHLY" "$AWK_FMT"'
    BEGIN {
      while ((getline l < monthly) > 0) {
        if (l ~ /^month,/) continue
        split(l, a, ",")
        if (since == "") since = a[1]
        mn += a[2]; ms += a[3]; mtok += a[4] * a[2]; mb += a[7]; msent += a[8] * a[2]
        if (a[6] > max) max = a[6]
      }
    }
    { n++; t[n] = $8; tok += $8; sent += $9; sess[$3]; proj[$4]++
      if ($8 > max) max = $8
      if ($8 > big) b++
      if (first == "") first = substr($1, 1, 10) }
    END {
      total = n + mn; s = ms
      for (k in sess) s++
      if (since == "") since = first
      print ""
      printf "── All-time (since %s) · %d prompts · %d sessions ──\n", since, total, s
      line = sprintf(" Prompt size  avg ~%s tok", fmt((tok + mtok) / total))
      if (n) line = line sprintf("   median ~%s%s", fmt(med), mn ? " (recent)" : "")
      print line sprintf("   longest ~%s", fmt(max))
      printf " Big prompts  %d over %d tok (%d%%)\n", b + mb, big, 100 * (b + mb) / total
      if (n >= 2 * every) {
        for (i = n - every + 1; i <= n; i++) r += t[i]
        for (i = n - 2 * every + 1; i <= n - every; i++) p += t[i]
        r /= every; p /= every
        trend = (r < 0.9 * p) ? "shrinking" : ((r > 1.1 * p) ? "growing" : "steady")
        printf " Trend        last %d avg ~%s tok (previous %d: ~%s) → %s\n", every, fmt(r), every, fmt(p), trend
      }
      printf " Context      avg %s sent per prompt\n", fmt((sent + msent) / total)
      if (n) {
        for (k in proj) if (proj[k] > pm) { pm = proj[k]; pk = k }
        printf " Busiest      %s (%d prompts)\n", pk, pm
      }
      print "───────────────────────────────────────────────"
    }' "$TMP/rows"
}

case "${1:-all}" in
  exit)
    flush_all
    rollup
    session_report "${2:?start time}" "${3:-0}" || exit 0
    total=$(total_prompts)
    last=$(cat "$MILESTONE" 2>/dev/null || echo 0)
    (( total / EVERY > last / EVERY )) && alltime_report
    echo "$total" > "$MILESTONE"
    ;;
  all)
    alltime_report
    ;;
  *)
    echo "usage: $0 exit <start-time> <seconds> | all" >&2
    exit 1
    ;;
esac
