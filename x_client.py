#!/usr/bin/env python3
"""
Post an image to X.

v1.1 media/upload was retired in June 2025, so this uses the v2 endpoints:
  POST /2/media/upload    multipart, OAuth 1.0a user context
  POST /2/media/metadata  alt text (best effort)
  POST /2/tweets          the post itself

Env vars (all four required unless DRY_RUN=1):
  X_API_KEY, X_API_SECRET, X_ACCESS_TOKEN, X_ACCESS_SECRET
"""

import os
import sys

import requests
from requests_oauthlib import OAuth1

MEDIA_UPLOAD = "https://api.x.com/2/media/upload"
MEDIA_METADATA = "https://api.x.com/2/media/metadata"
TWEETS = "https://api.x.com/2/tweets"

TIMEOUT = 60


class XError(RuntimeError):
    pass


def _auth():
    keys = ["X_API_KEY", "X_API_SECRET", "X_ACCESS_TOKEN", "X_ACCESS_SECRET"]
    vals = [os.environ.get(k, "") for k in keys]
    missing = [k for k, v in zip(keys, vals) if not v]
    if missing:
        raise XError("missing credentials: " + ", ".join(missing))
    return OAuth1(*vals)


def _check(resp, what):
    if resp.status_code not in (200, 201):
        raise XError(f"{what} failed [{resp.status_code}]: {resp.text[:400]}")
    return resp.json()


def upload_image(path, auth, alt=None):
    with open(path, "rb") as fh:
        body = _check(
            requests.post(
                MEDIA_UPLOAD,
                auth=auth,
                files={"media": (os.path.basename(path), fh, "image/png")},
                data={"media_category": "tweet_image"},
                timeout=TIMEOUT,
            ),
            "media upload",
        )

    media_id = (body.get("data") or body).get("id") or body.get("media_id_string")
    if not media_id:
        raise XError(f"no media id in upload response: {body}")

    if alt:
        # non-fatal: a missing alt text is not worth losing the post over
        try:
            requests.post(
                MEDIA_METADATA,
                auth=auth,
                json={"id": str(media_id), "metadata": {"alt_text": {"text": alt[:1000]}}},
                timeout=TIMEOUT,
            )
        except requests.RequestException as exc:
            print(f"alt text skipped: {exc}", file=sys.stderr)

    return str(media_id)


def post_image(path, text, alt=None, dry_run=False):
    if dry_run:
        print(f"[dry run] would post {path}\n{text}")
        return None

    auth = _auth()
    media_id = upload_image(path, auth, alt)
    body = _check(
        requests.post(
            TWEETS,
            auth=auth,
            json={"text": text[:280], "media": {"media_ids": [media_id]}},
            timeout=TIMEOUT,
        ),
        "post",
    )
    tweet_id = (body.get("data") or {}).get("id")
    print(f"posted to X: {tweet_id}")
    return tweet_id


def caption(week, top_team):
    return (
        f"Week {week} is in the books. {top_team} sits at the top of the power rankings. "
        f"Full board, standings and incentive watch below."
    )
