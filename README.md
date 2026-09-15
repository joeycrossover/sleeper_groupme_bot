# GBurg FFL bot

Replaces the Shiny app. Every Tuesday at 9:00am ET it posts power rankings and
the incentive watch to the league GroupMe as **@gburgfantasybot**, and a recap
graphic to X.

## Files

| File | Purpose |
| --- | --- |
| `gburg_bot.py` | Pulls Sleeper, computes rankings, posts to GroupMe, writes history |
| `graphic.py` | Builds the graphic payload and renders it to PNG via Playwright |
| `graphic_template.html` | 1200×1500 layout the PNG is screenshotted from |
| `x_client.py` | Media upload + post to X (v2 endpoints, OAuth 1.0a) |
| `say.py` | Ad-hoc message to the group chat, triggered manually |
| `history.csv` | Current season. Load-bearing — each week's `Rk` depends on the prior week's `Rk` |
| `history_2025.csv` | Archived 2025 season, reference only |
| `img3271.jpg` | Bot avatar used in GroupMe |
| `.github/workflows/power-rankings.yml` | Tuesday cron + manual trigger |
| `.github/workflows/bot-says.yml` | Manual trigger for `say.py` |

## Setup

**Secrets** (Settings → Secrets and variables → Actions → Secrets)

- `GROUPME_BOT_ID` — from dev.groupme.com/bots
- `X_API_KEY`, `X_API_SECRET` — app consumer keys
- `X_ACCESS_TOKEN`, `X_ACCESS_SECRET` — user tokens, generated **after** the app
  is set to Read and Write. A token minted while read-only uploads media fine
  and then 403s on the post.

**Variables** (same page, Variables tab)

- `LEAGUE_ID` — current season's Sleeper league id. Required; the script exits 1
  without it.
- `SEASON` — e.g. `2026`. Cosmetic, shown in the graphic subtitle.

**Permissions**: Settings → Actions → General → Workflow permissions → Read and write.

## Running it

Actions → Weekly Power Rankings → Run workflow.

| Input | Effect |
| --- | --- |
| `week` | Blank auto-detects the last completed week |
| `dry_run` | Renders the PNG, prints both messages, posts nothing anywhere |
| `skip_x` | Posts to GroupMe as normal, skips X entirely |

Manual runs set `FORCE=1`, which skips both the clock guard and the
already-posted guard.

Every run uploads the rendered PNG as a workflow artifact (30 days), including
dry runs — that's the fastest way to eyeball the graphic.

## Local

pip install -r requirements.txt
playwright install chromium
LEAGUE_ID=<id> DRY_RUN=1 FORCE=1 WEEK=1 python gburg_bot.py


`python graphic.py` renders `out/week_NN.png` from the live league and posts
nothing. `out/` is gitignored.

## Behavior notes

- **Week detection**: highest week where every matchup has scored. Can't fire
  early on an in-progress week regardless of when the job runs.
- **Clock guard**: scheduled runs exit if it's before 9am ET. Not an equality
  check — GitHub has delayed these crons by hours, and an `== 9` test silently
  drops the week when that happens. Duplicate protection comes from the
  already-posted guard, not the clock.
- **Two crons**: 13:00 UTC (9am EDT) and 14:00 UTC (9am EST). Both fire
  year-round; whichever runs first posts and writes history, the second sees the
  week already recorded and exits.
- **History is an upsert**: the target week is dropped before the new rows are
  written, so a forced re-run replaces that week rather than duplicating it.
- **X is best-effort**: `post_graphic` swallows all exceptions and runs after the
  history write. A Playwright crash or an X error costs the tweet, not the
  GroupMe post, and the week still gets recorded.
- **Week 1**: `Prev` seeds from standings position, so every `Chg` is even.
  Movement arrows start in week 2.
- **Message size**: GroupMe caps at 1000 chars. Rankings land around 570.
  `chunk()` splits with an `(n/m)` prefix if that's ever exceeded.

## New season

1. Update the `LEAGUE_ID` and `SEASON` variables.
2. `git mv history.csv history_<year>.csv` and let week 1 recreate it.

## Known quirks

- `pfp` uses the season-to-date `ppts` snapshot from the rosters endpoint, so
  recomputing an old week gives a slightly different value than the original run.
- The commit step runs `git add -A`. Add new output paths to `.gitignore` before
  they first appear, or they get committed.
- X media upload uses the simple multipart `POST /2/media/upload`. If that starts
  returning 400, the fallback is the chunked INIT/APPEND/FINALIZE flow.
