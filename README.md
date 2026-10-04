# claude-prompt-tracker

A Claude Code status line plus local prompt-size tracking, to show how much of each
turn is your prompt versus the context Claude sends, and how fast you use your plan limits.

Everything runs locally. Nothing is sent anywhere and no tokens are used.

## What you get

**Status line** (bottom of Claude Code):

```
➜  my-project git:(main) Sonnet
prompt ~97 │ sent 48.2k · got 912 │ 5h 34% · 7d 81%
```

| Item | Meaning |
|---|---|
| `prompt` | Your last typed prompt, estimated at ~4 characters per token |
| `sent` | Everything sent on the last API call (prompt + history + files + tool output) |
| `got` | Claude's latest reply |
| `5h` / `7d` | Pro/Max plan usage for the rolling 5-hour and weekly windows |

**Session report** when you quit `claude`, and an **all-time report** every
`CLAUDE_REPORT_EVERY` prompts or on demand with `claude-stats`.

## Install

Requires `jq` (built into macOS). [Oh My Posh](https://ohmyposh.dev) is optional; without
it the top line falls back to a plain robbyrussell-style prompt.

```sh
./install.sh
exec zsh
```

This points `statusLine` in `~/.claude/settings.json` at `statusline.sh` (backing up the
old file) and adds a `source` line to `~/.zshrc`.

To seed the log with prompts from before tracking started:

```sh
./backfill.sh ~/.claude/projects/*/*.jsonl    # every past session
```

Backfilled rows have no plan usage (`pct_5h`, `pct_7d`), since transcripts don't record it.
Prompts already in the log are skipped, so it is safe to re-run.

## Settings

Set in `~/.zshrc`, above the `source` line:

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_REPORT_EVERY` | `25` | Show the all-time report each time the prompt count passes a multiple of this |
| `CLAUDE_LOG_MAX_ROWS` | `5000` | Past this many rows, the oldest whole months roll into monthly summaries |
| `CLAUDE_BIG_PROMPT` | `250` | Prompts over this many tokens count as "big" |
| `CLAUDE_TRACKER_DATA` | `~/.claude/prompt-tracking` | Where the logs live |

## Data

Stored in `~/.claude/prompt-tracking/`, not in this repo. Prompt text is never recorded.

- `prompts.csv`: one row per prompt: `time, prompt_id, session, project, model, chars, words, est_tokens, sent, got, pct_5h, pct_7d`
- `prompts-monthly.csv`: monthly summaries of rolled-up rows
- `state/`: the in-progress prompt for each session
- `last-milestone`: prompt count at the last all-time report

## How it works

| File | Role |
|---|---|
| `statusline.sh` | Run by Claude Code on every status line refresh. Draws the status line and keeps the current prompt's numbers in `state/<session>`. When a new `prompt_id` appears, the previous prompt's row is appended to the log |
| `report.sh` | `exit` mode: saves pending prompts, rolls up old months, prints the session report and any due all-time report. `all` mode: all-time report |
| `backfill.sh` | Rebuilds rows from Claude Code transcripts for prompts sent before tracking started |
| `claude-tracker.zsh` | Defines the `claude` wrapper and the `claude-stats` alias |
| `lib.sh` | Shared paths and helpers |
| `ohmyposh/claude.omp.json` | Oh My Posh styling for the top line |

## Limits

- Prompt sizes are estimates. Everything else comes from the numbers Anthropic reports to Claude Code.
- `sent` is the context of each prompt's last API call, not the sum of every call during the prompt.
- Only terminal sessions started with the `claude` wrapper get exit reports. Claude Desktop isn't tracked.
