#!/usr/bin/env python3
"""
GBurg All Grown Up FFL -> GroupMe (@gburgfantasybot)

Posts the weekly power rankings + incentive watch after each completed week.
Port of the Shiny app's ranking logic; history is append-only in history.csv.

Env vars:
  GROUPME_BOT_ID  (required unless DRY_RUN=1)
  LEAGUE_ID       (default: the 2025 GBurg league)
  WEEK            (optional int; override auto-detected completed week)
  DRY_RUN         (1 = print messages, don't post, don't write history)
  FORCE           (1 = skip the 9am-ET guard and the already-posted guard)
"""

import json
import os
import sys
from datetime import datetime
from zoneinfo import ZoneInfo

import pandas as pd
import requests

LEAGUE_ID = os.environ.get("LEAGUE_ID", "1256817986006683648")
BOT_ID = os.environ.get("GROUPME_BOT_ID", "")
DRY_RUN = os.environ.get("DRY_RUN") == "1"
FORCE = os.environ.get("FORCE") == "1"

REGULAR_SEASON_WEEKS = 14
HISTORY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "history.csv")
SLEEPER = "https://api.sleeper.app/v1"
GROUPME_POST = "https://api.groupme.com/v3/bots/post"
GROUPME_LIMIT = 1000

# component -> weight, straight from the R weighted.mean() call
WEIGHTS = {
    "Prev": 1,
    "standings": 1,
    "wk_win_rank": 1,
    "wins_rank": 3,
    "loss_rank": 1,
    "wk_pf_rank": 2,
    "total_pf_rank": 5,
    "pfp_rank": 2,
    "streak_rank": 1,
}

# incentive payouts
PAYOUT_SEASON_PF = 50
PAYOUT_WEEKLY_PF = 50
PAYOUT_RS_CHAMP = 100


# ---------- Sleeper ----------

def get(path):
    r = requests.get(f"{SLEEPER}{path}", timeout=30)
    r.raise_for_status()
    return r.json()


def load_users():
    rows = []
    for u in get(f"/league/{LEAGUE_ID}/users"):
        meta = u.get("metadata") or {}
        rows.append({
            "user_id": u["user_id"],
            "display_name": u["display_name"],
            "team_name": (meta.get("team_name") or u["display_name"]).strip(),
        })
    return pd.DataFrame(rows)


def load_rosters():
    rows = []
    for r in get(f"/league/{LEAGUE_ID}/rosters"):
        s = r.get("settings") or {}
        rows.append({
            "owner_id": r.get("owner_id"),
            "roster_id": r["roster_id"],
            "fpts": s.get("fpts", 0) + s.get("fpts_decimal", 0) / 100,
            "fpts_against": s.get("fpts_against", 0) + s.get("fpts_against_decimal", 0) / 100,
            "ppts": s.get("ppts", 0) + s.get("ppts_decimal", 0) / 100,
            "wins": s.get("wins", 0),
            "losses": s.get("losses", 0),
            "ties": s.get("ties", 0),
            "streak": s.get("streak", ""),
        })
    return pd.DataFrame(rows)


def load_matchups(max_week=REGULAR_SEASON_WEEKS):
    rows = []
    for wk in range(1, max_week + 1):
        try:
            data = get(f"/league/{LEAGUE_ID}/matchups/{wk}")
        except requests.HTTPError:
            continue
        if not data:
            continue
        for m in data:
            if m.get("matchup_id") is None:
                continue
            rows.append({
                "week": wk,
                "roster_id": m["roster_id"],
                "matchup_id": m["matchup_id"],
                "points": m.get("points") or 0.0,
            })
    return pd.DataFrame(rows)


def detect_completed_week(matchups):
    """Highest week where every matchup actually scored. Tuesday-safe."""
    done = []
    for wk, g in matchups.groupby("week"):
        if (g["points"] > 0).all():
            done.append(wk)
    return max(done) if done else 0


# ---------- rankings ----------

def rank_avg(s, ascending=True):
    """R's rank() default: ties.method = 'average'."""
    return s.rank(method="average", ascending=ascending)


def build_streak(wins_seq):
    """Replicates the R streak loop: consecutive W/L run as e.g. '3W' / '2L'."""
    out, count = [], 0
    for i, w in enumerate(wins_seq):
        if w == 1:
            count = 1 if (i == 0 or wins_seq[i - 1] == 0) else count + 1
            out.append(f"{count}W")
        else:
            count = 1 if (i == 0 or wins_seq[i - 1] == 1) else count + 1
            out.append(f"{count}L")
    return out


def compute_week(users, rosters, matchups, week, history):
    """Compute the power ranking rows for a single completed week."""
    df = matchups[matchups.week <= week].merge(
        rosters[["owner_id", "roster_id", "ppts"]], on="roster_id"
    ).merge(users, left_on="owner_id", right_on="user_id")
    df = df.rename(columns={"points": "wk_pf"})

    # per-matchup W/L
    df["wk_win"] = 0
    df["wk_loss"] = 0
    for (_, _), idx in df.groupby(["week", "matchup_id"]).groups.items():
        g = df.loc[idx, "wk_pf"]
        df.loc[idx, "wk_win"] = (g == g.max()).astype(int)
        df.loc[idx, "wk_loss"] = (g == g.min()).astype(int)

    # cumulative by team
    df = df.sort_values(["display_name", "week"])
    df["total_pf"] = df.groupby("display_name")["wk_pf"].cumsum()
    df["wins"] = df.groupby("display_name")["wk_win"].cumsum()
    df["losses"] = df.groupby("display_name")["wk_loss"].cumsum()
    df["pfp"] = (df["total_pf"] / df["ppts"]).round(3)
    df["streak"] = (
        df.groupby("display_name")["wk_win"]
        .transform(lambda s: pd.Series(build_streak(list(s)), index=s.index))
    )

    cur = df[df.week == week].copy()
    cur["ties"] = 0
    cur["streak_num"] = cur["streak"].map(
        lambda s: int(s[:-1]) if s.endswith("W") else -int(s[:-1])
    )

    # standings position within the week
    cur = cur.sort_values(["wins", "total_pf"], ascending=[False, False]).reset_index(drop=True)
    cur["standings"] = cur.index + 1

    cur["wk_win_rank"] = rank_avg(cur["wk_win"], ascending=False)
    cur["wins_rank"] = rank_avg(cur["wins"], ascending=False)
    cur["loss_rank"] = rank_avg(cur["losses"], ascending=True)
    cur["wk_pf_rank"] = rank_avg(cur["wk_pf"], ascending=False)
    cur["total_pf_rank"] = rank_avg(cur["total_pf"], ascending=False)
    cur["pfp_rank"] = rank_avg(cur["pfp"], ascending=False)
    cur["streak_rank"] = rank_avg(cur["streak_num"], ascending=False)

    # previous week's Rk
    if week == 1 or history.empty or (history.week == week - 1).sum() == 0:
        cur["Prev"] = cur["standings"].astype(float)
    else:
        prev = history[history.week == week - 1].set_index("display_name")["Rk"]
        cur["Prev"] = cur["display_name"].map(prev).fillna(cur["standings"]).astype(float)

    score = sum(cur[c] * w for c, w in WEIGHTS.items()) / sum(WEIGHTS.values())
    cur["_score"] = score
    # ties broken by standings so ranks stay integral (R's rank() would emit x.5)
    cur = cur.sort_values(["_score", "standings"]).reset_index(drop=True)
    cur["Rk"] = (cur.index + 1).astype(float)
    cur["Chg"] = cur["Prev"] - cur["Rk"]

    cols = ["week", "display_name", "team_name", "matchup_id", "wk_pf", "total_pf", "ppts", "pfp",
            "wins", "losses", "ties", "streak", "wk_win", "wk_loss", "standings", "streak_num",
            "wk_win_rank", "wins_rank", "loss_rank", "wk_pf_rank", "total_pf_rank", "pfp_rank",
            "streak_rank", "Prev", "Rk", "Chg"]
    return cur[cols]


# ---------- messages ----------

def arrow(chg):
    if chg > 0:
        return f"▲{int(chg)}"
    if chg < 0:
        return f"▼{int(-chg)}"
    return "—"


def rankings_message(week, rows):
    lines = [f"🏈 REAL MF POWER RANKINGS — Week {week}", ""]
    for _, r in rows.sort_values("Rk").iterrows():
        lines.append(
            f"{int(r.Rk)}. {r.team_name} {arrow(r.Chg)}  "
            f"({int(r.wins)}-{int(r.losses)}, {r.total_pf:.1f} PF, {r.streak})"
        )
    return "\n".join(lines)


def incentive_message(week, users, rosters, matchups):
    standings = rosters.merge(users, left_on="owner_id", right_on="user_id")
    standings = standings.sort_values(["wins", "fpts"], ascending=[False, False])

    pf_lead = standings.sort_values("fpts", ascending=False).iloc[0]
    champ = standings.iloc[0]

    played = matchups[matchups.week <= week].merge(
        rosters[["owner_id", "roster_id"]], on="roster_id"
    ).merge(users, left_on="owner_id", right_on="user_id")
    hi = played.sort_values("points", ascending=False).iloc[0]

    champ_label = "Reg. Season Champ" if week >= REGULAR_SEASON_WEEKS else "Reg. Season Leader"
    return "\n".join([
        f"💰 INCENTIVE WATCH — Week {week}",
        "",
        f"Season PF Leader (${PAYOUT_SEASON_PF}): {pf_lead.team_name} — {pf_lead.fpts:.1f}",
        f"Weekly High (${PAYOUT_WEEKLY_PF}): {hi.team_name} — {hi.points:.1f} (Wk {int(hi.week)})",
        f"{champ_label} (${PAYOUT_RS_CHAMP}): {champ.team_name} — "
        f"{int(champ.wins)}-{int(champ.losses)}",
    ])


def chunk(text, limit=GROUPME_LIMIT):
    """Split on newlines if a message ever outgrows GroupMe's 1000-char cap."""
    if len(text) <= limit:
        return [text]
    parts, cur = [], ""
    for line in text.split("\n"):
        if len(cur) + len(line) + 1 > limit - 8:
            parts.append(cur.rstrip())
            cur = ""
        cur += line + "\n"
    if cur.strip():
        parts.append(cur.rstrip())
    return [f"({i}/{len(parts)})\n{p}" for i, p in enumerate(parts, 1)]


def post(text):
    for part in chunk(text):
        if DRY_RUN:
            print(part)
            print("-" * 60)
            continue
        r = requests.post(
            GROUPME_POST,
            data=json.dumps({"bot_id": BOT_ID, "text": part}),
            headers={"Content-Type": "application/json"},
            timeout=30,
        )
        if r.status_code not in (200, 201, 202):
            raise RuntimeError(f"GroupMe returned {r.status_code}: {r.text}")


# ---------- main ----------

def main():
    now_et = datetime.now(ZoneInfo("America/New_York"))
    if not FORCE and now_et.hour != 9:
        print(f"Not 9am ET (currently {now_et:%H:%M %Z}) — skipping.")
        return 0

    if not BOT_ID and not DRY_RUN:
        print("GROUPME_BOT_ID is not set.", file=sys.stderr)
        return 1

    history = (
        pd.read_csv(HISTORY) if os.path.exists(HISTORY)
        else pd.DataFrame(columns=["week", "display_name", "Rk"])
    )

    users = load_users()
    rosters = load_rosters()
    matchups = load_matchups()

    week = int(os.environ["WEEK"]) if os.environ.get("WEEK") else detect_completed_week(matchups)
    if week < 1:
        print("No completed week yet — nothing to post.")
        return 0
    if week > REGULAR_SEASON_WEEKS:
        print(f"Week {week} is past the regular season — nothing to post.")
        return 0
    if not FORCE and not history.empty and (history.week == week).any():
        print(f"Week {week} already in history — nothing to post.")
        return 0

    rows = compute_week(users, rosters, matchups, week, history)

    msg_rank = rankings_message(week, rows)
    msg_inc = incentive_message(week, users, rosters, matchups)
    post(msg_rank)
    post(msg_inc)

    if not DRY_RUN:
        history = history[history.week != week] if not history.empty else history
        out = pd.concat([history, rows], ignore_index=True).sort_values(["week", "Rk"])
        out.to_csv(HISTORY, index=False)
        print(f"Posted week {week} and appended {len(rows)} rows to history.csv")

    return 0


if __name__ == "__main__":
    sys.exit(main())
