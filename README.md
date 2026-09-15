# GBurg FFL → GroupMe bot

Replaces the Shiny app. Posts two messages to the league chat as **@gburgfantasybot**
every Tuesday at 9:00am ET: power rankings and the incentive watch.

## Files

| File | Purpose |
| --- | --- |
| `gburg_bot.py` | Pulls Sleeper, computes rankings, posts to GroupMe, writes history |
| `say.py` | Ad-hoc message to the group chat, triggered manually |
| `history.csv` | Current season. Load-bearing — each week's `Rk` depends on the prior week's `Rk` |
| `history_2025.csv` | Archived 2025 season, kept for reference only |
| `img3271.jpg` | Bot avatar used in GroupMe |
| `requirements.txt` | pandas, requests |
| `.github/workflows/power-rankings.yml` | Tuesday 9am ET cron + manual trigger |
| `.github/workflows/bot-says.yml` | Manual trigger for `say.py` |

## Setup

1. Repo → Settings → Secrets and variables → Actions → **Secrets**
   - `GROUPME_BOT_ID` — bot id from dev.groupme.com/bots
2. Same page, **Variables** tab
   - `LEAGUE_ID` — the current Sleeper league id. Set this every season; the
     hardcoded fallback in `gburg_bot.py` is not a valid league id.
3. Settings → Actions → General → Workflow permissions → **Read and write**
   (lets the job commit `history.csv` back)
4. Actions → Weekly Power Rankings → **Run workflow** with `dry_run = true` to
   smoke-test, then `dry_run = false` for a real post.

## Local run

pip install -r requirements.txt
DRY_RUN=1 FORCE=1 WEEK=1 python gburg_bot.py

`DRY_RUN=1` prints both messages and skips the history write entirely, so a local
run never touches GroupMe or the CSV.

## Behavior notes

- **Week detection**: highest week where every matchup has scored. Safe to run
  Tuesday morning; won't fire early on an in-progress week.
- **Clock guard**: scheduled runs exit unless it's the 9 o'clock hour in
  `America/New_York`. That's what makes the two UTC crons safe — 13:00 UTC is
  9am EDT, 14:00 UTC is 9am EST, and only one of them passes on any given date.
  A run delayed past 9:59 ET exits without posting.
- **Already-posted guard**: exits if the week is already in `history.csv`.
  Manual runs set `FORCE=1`, which skips both guards.
- **History write is an upsert**: the target week is dropped before the new rows
  are concatenated, so a forced re-run replaces that week rather than duplicating it.
- **Week 1**: `Prev` seeds from standings position, so every `Chg` is even.
  Movement arrows start in week 2.
- **Message size**: GroupMe caps at 1000 chars. Rankings land around 570,
  incentive watch around 190. `chunk()` splits with an `(n/m)` prefix if a
  message ever outgrows it.

## New season

1. Set the `LEAGUE_ID` variable to the new league.
2. `git mv history.csv history_<year>.csv` and let week 1 recreate it.

## Known quirks

- `pfp` uses the season-to-date `ppts` snapshot from the rosters endpoint, so
  recomputing an old week gives a slightly different value than the original run.
- The commit step runs `git add -A`, so anything left in the working tree gets
  committed. Add new scratch/output paths to `.gitignore` before they first appear.
