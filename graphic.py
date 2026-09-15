#!/usr/bin/env python3
"""
Weekly recap graphic for the GBurg FFL bot.

Turns the same Sleeper frames gburg_bot.py already builds into a PNG:
final scores, power rankings, standings, incentive watch.

    payload = build_payload(users, rosters, matchups, rows, incentives, week)
    png     = render_png(payload, "out/week_01.png")

Rendering needs Playwright's chromium:
    pip install playwright && playwright install --with-deps chromium
"""

import json
import os

import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(HERE, "graphic_template.html")

# must match .frame in the template — 4:5 posts uncropped on X
FRAME_W = 1200
FRAME_H = 1500
SCALE = 2  # retina; 2400x3000 output, still under X's 5MB image cap


# ---------- payload ----------

def team_lookup(users, rosters):
    """roster_id -> team_name, the same merge the Shiny app does."""
    merged = rosters[["owner_id", "roster_id"]].merge(
        users, left_on="owner_id", right_on="user_id"
    )
    return dict(zip(merged["roster_id"], merged["team_name"]))


def week_games(matchups, names, week):
    """Pair rosters by matchup_id, winner first, highest-scoring game first."""
    games = []
    wk = matchups[matchups.week == week]
    for _, g in wk.groupby("matchup_id"):
        sides = [
            {"team": names.get(r.roster_id, f"Roster {r.roster_id}"),
             "pts": round(float(r.points), 1)}
            for r in g.sort_values("points", ascending=False).itertuples()
        ]
        if len(sides) != 2:  # bye or a broken matchup_id; skip rather than guess
            continue
        games.append(sides)
    games.sort(key=lambda s: s[0]["pts"], reverse=True)
    return games


def glance_lines(games):
    """Three one-liners under the incentive block."""
    if not games:
        return []
    margins = [(a["pts"] - b["pts"], a, b) for a, b in games]
    widest = max(margins, key=lambda m: m[0])
    closest = min(margins, key=lambda m: m[0])
    lowest = min((s for g in games for s in g), key=lambda s: s["pts"])
    return [
        ["Biggest margin", f"{widest[1]['team']} by {widest[0]:.1f}"],
        ["Closest game", f"{closest[1]['team']} by {closest[0]:.1f}"],
        ["Lowest output", f"{lowest['team']}, {lowest['pts']:.1f}"],
    ]


def build_payload(users, rosters, matchups, rows, incentives, week, season=None):
    """
    rows       -- compute_week() output for this week
    incentives -- incentive_rows() output: list of (amount, label, team, value)
    """
    names = team_lookup(users, rosters)
    games = week_games(matchups, names, week)

    # season points against, straight off the roster settings
    pa = rosters[["owner_id", "fpts_against"]].merge(
        users, left_on="owner_id", right_on="user_id"
    )
    pa = {r.team_name: round(float(r.fpts_against), 1) for r in pa.itertuples()}

    ranks = [
        {"rk": int(r.Rk), "team": r.team_name, "w": int(r.wins), "l": int(r.losses),
         "pf": round(float(r.total_pf), 1), "strk": r.streak, "chg": int(r.Chg)}
        for r in rows.sort_values("Rk").itertuples()
    ]

    n_games = len(games)
    tightest = min((a["pts"] - b["pts"] for a, b in games), default=0)
    purse_total = sum(int(str(a).lstrip("$")) for a, _, _, _ in incentives)

    return {
        "week": int(week),
        "subtitle": " · ".join(
            x for x in (f"{season} season" if season else None,
                        f"{len(ranks)} teams", "powered by Sleeper") if x),
        "notes": {
            "games": f"{n_games} games, closest decided by {tightest:.1f}.",
            "purse": f"${purse_total} on the table.",
        },
        "games": games,
        "ranks": ranks,
        "pa": pa,
        "purse": [
            {"amt": amt, "what": label, "who": team, "val": val}
            for amt, label, team, val in incentives
        ],
        "glance": glance_lines(games),
    }


# ---------- render ----------

def render_html(payload):
    with open(TEMPLATE, encoding="utf-8") as fh:
        template = fh.read()
    # json.dumps is safe here: no user-controlled </script> can reach it,
    # but escape the sequence anyway in case a team name gets cute.
    blob = json.dumps(payload, ensure_ascii=False).replace("</", "<\\/")
    return template.replace("__PAYLOAD__", blob)


def render_png(payload, out_path):
    from playwright.sync_api import sync_playwright

    html = render_html(payload)
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)

    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(
            viewport={"width": FRAME_W, "height": FRAME_H},
            device_scale_factor=SCALE,
        )
        page.set_content(html, wait_until="networkidle")
        page.wait_for_function("document.fonts.ready.then(() => true)")
        page.locator(".frame").screenshot(path=out_path)
        browser.close()

    return out_path


def alt_text(payload):
    """Screen-reader text for the post. X caps this at 1000 characters."""
    top = payload["ranks"][:3]
    lines = [f"Week {payload['week']} recap for the G-Burg All Grown Up fantasy league."]
    lines.append("Power rankings top three: " + ", ".join(
        f"{i + 1} {r['team']}" for i, r in enumerate(top)) + ".")
    if payload["games"]:
        a, b = payload["games"][0]
        lines.append(f"Highest-scoring game: {a['team']} {a['pts']} over {b['team']} {b['pts']}.")
    return " ".join(lines)[:1000]


if __name__ == "__main__":
    # smoke test against the live league, no posting
    import gburg_bot as bot

    users, rosters = bot.load_users(), bot.load_rosters()
    matchups = bot.load_matchups()
    week = int(os.environ.get("WEEK") or bot.detect_completed_week(matchups))
    history = (pd.read_csv(bot.HISTORY) if os.path.exists(bot.HISTORY)
               else pd.DataFrame(columns=["week", "display_name", "Rk"]))
    rows = bot.compute_week(users, rosters, matchups, week, history)
    inc = bot.incentive_rows(week, users, rosters, matchups)

    payload = build_payload(users, rosters, matchups, rows, inc, week,
                            season=os.environ.get("SEASON"))
    print(render_png(payload, f"out/week_{week:02d}.png"))
