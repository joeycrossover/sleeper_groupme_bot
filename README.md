# GBurg FFL → GroupMe bot

Replaces the Shiny app. Posts two messages to the league chat as
**@gburgfantasybot** every Tuesday at 9:00am ET: power rankings and the
incentive watch.

## Files

| File | Purpose |
|---|---|
| `gburg_bot.py` | Pulls Sleeper, computes rankings, posts to GroupMe, appends history |
| `history.csv` | Seeded from `power_rankings.rds` (weeks 1–14, deduped). Load-bearing — `Rk` depends on the prior week's `Rk` |
| `requirements.txt` | pandas, requests |
| `.github/workflows/power-rankings.yml` | Tuesday 9am ET cron + manual trigger |

## Setup

1. Commit these files to the repo root (workflow at `.github/workflows/`).
2. Repo → Settings → Secrets and variables → Actions → **New repository secret**
   - Name: `GROUPME_BOT_ID`, value: your bot id from dev.groupme.com/bots
3. Same page, **Variables** tab → `LEAGUE_ID` = `1256817986006683648`
   (optional — the script defaults to this; set it each new season)
4. Settings → Actions → General → Workflow permissions → **Read and write**
   (lets the job commit `history.csv` back)
5. Actions tab → Weekly Power Rankings → **Run workflow** with
   `week = 14` and `dry_run = true` to smoke-test without posting.
6. Same, `dry_run = false`, to send a real test post.

## Local run

    pip install -r requirements.txt
    DRY_RUN=1 FORCE=1 WEEK=14 python gburg_bot.py

## Behavior notes

- **Week detection**: highest week where every matchup has scored. Safe to run
  Tuesday morning; won't fire early on an in-progress week.
- **Idempotent**: exits without posting if the week is already in `history.csv`.
  Manual runs set `FORCE=1` and will repost/overwrite that week.
- **Clock guard**: scheduled runs exit unless it's the 9 o'clock hour in
  `America/New_York`. That's what makes the two UTC crons safe.
- **Message size**: GroupMe caps at 1000 chars. Rankings land around 570,
  incentive watch around 190. `chunk()` splits with an `(n/m)` prefix if a
  message ever outgrows it.
- **New season**: set the `LEAGUE_ID` variable to the new Sleeper league and
  archive `history.csv` (week 1 self-seeds `Prev` from standings).

## Known quirks inherited from the RDS

- Week 7 was written twice with different `Rk`; the duplicate was dropped,
  keeping the first copy (which is what week 8's `Prev` had matched).
- Week 2's stored `Rk` isn't reproducible from its own components — weights
  appear to have been tuned after week 2. Historical rows are frozen as-is.
- johnhallock's week 3 `wk_pf` is 1.00 higher than every cumulative total
  built on it. Frozen in the seed; live runs recompute both from one pull.
- `pfp` uses the season-to-date `ppts` snapshot from the rosters endpoint, so
  it drifts if you ever recompute an old week. Append-only avoids this.
