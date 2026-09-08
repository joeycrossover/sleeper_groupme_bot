#!/usr/bin/env python3
"""Post an arbitrary message to the league chat as @gburgfantasybot.

    GROUPME_BOT_ID=... MESSAGE="hello" python say.py

Set DRY_RUN=1 to print exactly what would be sent, without sending it.

Literal \n in MESSAGE becomes a real newline, since GitHub Actions inputs
are single-line. IMAGE_URL is optional and must be a groupme.com image
service URL (i.groupme.com) -- GroupMe rejects outside hosts.
"""
import json
import os
import sys

import requests

GROUPME_POST = "https://api.groupme.com/v3/bots/post"
LIMIT = 1000


def chunk(text, limit=LIMIT):
    """Split to fit GroupMe's cap, preferring line breaks but hard-wrapping
    any single line that is too long to break."""
    if len(text) <= limit:
        return [text]
    budget = limit - 10  # headroom for the "(n/m)\n" prefix

    pieces = []
    for line in text.split("\n"):
        while len(line) > budget:
            pieces.append(line[:budget])
            line = line[budget:]
        pieces.append(line)

    parts, cur = [], ""
    for piece in pieces:
        candidate = piece if not cur else cur + "\n" + piece
        if len(candidate) > budget:
            if cur:
                parts.append(cur)
            cur = piece
        else:
            cur = candidate
    if cur.strip():
        parts.append(cur)

    parts = [p for p in parts if p.strip()]
    return [f"({i}/{len(parts)})\n{p}" for i, p in enumerate(parts, 1)]


def main():
    bot_id = os.environ.get("GROUPME_BOT_ID", "")
    text = os.environ.get("MESSAGE", "").replace("\\n", "\n").strip()
    image_url = os.environ.get("IMAGE_URL", "").strip()
    dry_run = os.environ.get("DRY_RUN") == "1"

    if not bot_id and not dry_run:
        print("GROUPME_BOT_ID is not set.", file=sys.stderr)
        return 1
    if not text and not image_url:
        print("Nothing to send.", file=sys.stderr)
        return 1

    parts = chunk(text) if text else [""]
    for i, part in enumerate(parts):
        payload = {"bot_id": bot_id, "text": part}
        # attach the image to the last message only
        if image_url and i == len(parts) - 1:
            payload["attachments"] = [{"type": "image", "url": image_url}]

        if dry_run:
            print(f"--- message {i + 1} of {len(parts)} ({len(part)} chars) ---")
            print(part)
            if payload.get("attachments"):
                print(f"[image attached: {image_url}]")
            continue

        r = requests.post(
            GROUPME_POST,
            data=json.dumps(payload),
            headers={"Content-Type": "application/json"},
            timeout=30,
        )
        if r.status_code not in (200, 201, 202):
            print(f"GroupMe returned {r.status_code}: {r.text}", file=sys.stderr)
            return 1
        print(f"Sent: {part[:80]}{'...' if len(part) > 80 else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
