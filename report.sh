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

# Shared awk UI helpers: colour only when c=1; dim labels, bold header
AWK_UI='function esc(code) { return c ? sprintf("%c[%sm", 27, code) : "" }
function lab(s) { return esc("2") sprintf("%-16s", s) esc("0") }
function rule() { return esc("2") "────────────────────────────────────" esc("0") }'

# Colour only on a terminal, and not when NO_COLOR is set
COLOR=0
[ -t 1 ] && [ -z "${NO_COLOR:-}" ] && COLOR=1

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
  local start=$1 secs=$2 dur med
  rows | awk -F, -v s="$start" '$1 >= s' > "$TMP/session"
  [ -s "$TMP/session" ] || return 1

  if (( secs >= 3600 )); then dur="$(( secs / 3600 ))h $(( secs % 3600 / 60 ))m"
  else dur="$(( secs / 60 ))m"; fi
  med=$(cut -d, -f8 "$TMP/session" | median)

  awk -F, -v dur="$dur" -v secs="$secs" -v med="$med" -v big="$BIG" -v c="$COLOR" \
    "$AWK_FMT$AWK_UI"'
    # Julian day * 86400 + time of day: seconds on a continuous scale
    function stamp(ts,   y, m, d, a, y2, m2) {
      y = substr(ts, 1, 4) + 0; m = substr(ts, 6, 2) + 0; d = substr(ts, 9, 2) + 0
      a = int((14 - m) / 12); y2 = y + 4800 - a; m2 = m + 12 * a - 3
      return (d + int((153 * m2 + 2) / 5) + 365 * y2 + int(y2 / 4) - int(y2 / 100) + int(y2 / 400) - 32045) * 86400 \
             + substr(ts, 12, 2) * 3600 + substr(ts, 15, 2) * 60 + substr(ts, 18, 2)
    }
    function clock(mins) { mins = mins % 1440; return sprintf("%02d:%02d", int(mins / 60), mins % 60) }
    function bar(name, p, was,   k, i, out) {
      k = int(p * 12 / 100 + 0.5); if (p > 0 && k < 1) k = 1; if (k > 12) k = 12
      out = (p >= 90 ? esc("31") : (p >= 70 ? esc("33") : ""))
      for (i = 1; i <= k; i++) out = out "█"
      out = out esc("0") esc("2")
      for (i = k + 1; i <= 12; i++) out = out "░"
      printf "%s%-9s%s%s%s %3d%%  (was %d%%)\n", esc("2"), name, esc("0"), out, esc("0"), p, was
    }
    BEGIN { sp[1]="▁"; sp[2]="▂"; sp[3]="▃"; sp[4]="▄"; sp[5]="▅"; sp[6]="▆"; sp[7]="▇"; sp[8]="█" }
    { n++; tok += $8; sent += $9; got += $10
      if ($8 > max) max = $8
      if ($8 > big) b++
      S[n] = $9; T[n] = stamp($1); clk[n] = substr($1, 12, 5)
      if (!($5 in mc)) mo[++nm] = $5
      mc[$5]++
      if ($11 != "") { if (f5 == "") f5 = $11; l5 = $11 }
      if ($12 != "") { if (f7 == "") f7 = $12; l7 = $12 } }
    END {
      long = (n >= 10 || secs >= 1800)
      print ""
      printf "%sClaude session · %s · %d prompt%s%s\n", esc("1"), dur, n, (n == 1 ? "" : "s"), esc("0")
      print rule()
      printf "%s~%s tok median · longest ~%s\n", lab("Prompt size"), fmt(med), fmt(max)
      if (long) printf "%s%d over %d tok\n", lab("Long prompts"), b, big
      printf "%savg %s per prompt\n", lab("Context"), fmt(sent / n)
      printf "%savg %s per prompt\n", lab("Reply"), fmt(got / n)
      if (sent > 0) printf "%s%.1f%% of input\n", lab("Your share"), 100 * tok / sent

      if (long) {
        print ""
        if (n >= 2) {
          pts = (n < 12 ? n : 12); lo = hi = S[1]
          for (i = 2; i <= n; i++) { if (S[i] < lo) lo = S[i]; if (S[i] > hi) hi = S[i] }
          line = ""
          for (k = 1; k <= pts; k++) {
            v = S[int((k - 1) * (n - 1) / (pts - 1) + 1)]
            lv = (hi > lo) ? int((v - lo) / (hi - lo) * 7) + 1 : 1
            line = line sp[lv]
          }
          printf "%s%s → %s   %s\n", lab("Context growth"), fmt(S[1]), fmt(S[n]), line
        }
        gap = secs / n
        pace = (gap >= 60) ? sprintf("1 prompt / %dm", gap / 60 + 0.5) : sprintf("1 prompt / %ds", gap)
        # busiest 30-minute window, anchored at a prompt
        best = 0
        for (i = 1; i <= n; i++) {
          cnt = 0
          for (j = i; j <= n && T[j] - T[i] < 1800; j++) cnt++
          if (cnt > best) { best = cnt; bi = i }
        }
        if (n >= 10) {
          m0 = substr(clk[bi], 1, 2) * 60 + substr(clk[bi], 4, 2)
          pace = pace sprintf(" · busiest %s–%s (%d)", clk[bi], clock(m0 + 30), best)
        }
        printf "%s%s\n", lab("Pace"), pace
      }

      models = ""
      for (i = 1; i <= nm; i++)
        models = models (i > 1 ? " · " : "") mo[i] (nm > 1 ? sprintf(" (%d)", mc[mo[i]]) : "")
      printf "%s%s\n", lab("Models"), models

      if (f5 != "" || f7 != "") {
        print ""
        if (f5 != "") bar("5h limit", l5, f5)
        if (f7 != "") bar("7d limit", l7, f7)
      }
      print rule()
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

  awk -F, -v med="$med" -v every="$EVERY" -v big="$BIG" -v monthly="$MONTHLY" -v c="$COLOR" "$AWK_FMT$AWK_UI"'
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
      printf "%sClaude all-time · since %s · %d prompts · %d session%s%s\n", esc("1"), since, total, s, (s == 1 ? "" : "s"), esc("0")
      print rule()
      line = sprintf("avg ~%s tok", fmt((tok + mtok) / total))
      if (n) line = line sprintf(" · median ~%s%s", fmt(med), mn ? " (recent)" : "")
      print lab("Prompt size") line sprintf(" · longest ~%s", fmt(max))
      printf "%s%d over %d tok (%d%%)\n", lab("Big prompts"), b + mb, big, 100 * (b + mb) / total
      if (n >= 2 * every) {
        for (i = n - every + 1; i <= n; i++) r += t[i]
        for (i = n - 2 * every + 1; i <= n - every; i++) p += t[i]
        r /= every; p /= every
        trend = (r < 0.9 * p) ? "shrinking" : ((r > 1.1 * p) ? "growing" : "steady")
        printf "%slast %d avg ~%s tok (previous %d: ~%s) → %s\n", lab("Trend"), every, fmt(r), every, fmt(p), trend
      }
      printf "%savg %s per prompt\n", lab("Context"), fmt((sent + msent) / total)
      if (n) {
        for (k in proj) if (proj[k] > pm) { pm = proj[k]; pk = k }
        printf "%s%s (%d prompts)\n", lab("Busiest"), pk, pm
      }
      print rule()
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
