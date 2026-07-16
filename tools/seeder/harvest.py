# /// script
# requires-python = ">=3.12"
# dependencies = ["httpx>=0.27"]
# ///
"""Build the discussion-prompt seeder DB.

Two ways in, both landing in the same SQLite + diff-able JSONL:

1. --import FILE.jsonl    load prompts you pulled yourself (reddit blocks
                          datacenter IPs; if you have a working pull, feed it
                          here). Each line: {subreddit, title, permalink,
                          selftext?, score?, num_comments?, created_utc?,
                          comments: [{score, body}, ...]}.

2. (default)             harvest via Arctic Shift (arctic-shift.photon-reddit.com),
                          the free Pushshift successor. Samples monthly windows
                          per subreddit and keeps the highest-scored posts +
                          their top comments. Approximates "top by month" —
                          true tops need Arctic Shift's bulk dumps.

    uv run tools/seeder/harvest.py --import mypull.jsonl
    uv run tools/seeder/harvest.py --years 3 --per-month 10
    uv run tools/seeder/harvest.py --subs AskReddit --years 1

Idempotent: re-runs skip posts already stored.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import time
from datetime import date
from pathlib import Path

import httpx

SUBS = ["AskReddit", "AITAH", "BestofRedditorUpdates", "tifu", "todayilearned"]
API = "https://arctic-shift.photon-reddit.com/api"
UA = "party-line-seeder/0.2 (discussion-prompt research; github.com/notactuallytreyanastasio/party_line)"
COMMENTS_PER_POST = 10
SAMPLE_PER_MONTH = 100
PAUSE_S = 0.8

SCHEMA = """
CREATE TABLE IF NOT EXISTS posts (
  id TEXT PRIMARY KEY,
  subreddit TEXT NOT NULL,
  title TEXT NOT NULL,
  selftext TEXT,
  permalink TEXT,
  score INTEGER,
  num_comments INTEGER,
  created_utc INTEGER,
  bucket TEXT,
  comments_fetched INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS comments (
  id TEXT PRIMARY KEY,
  post_id TEXT NOT NULL REFERENCES posts(id),
  rank INTEGER,
  score INTEGER,
  body TEXT
);
CREATE INDEX IF NOT EXISTS comments_post ON comments(post_id);
"""


def months(years: int):
    today = date.today().replace(day=1)
    y, m = today.year, today.month
    for _ in range(years * 12):
        start = date(y, m, 1)
        m -= 1
        if m == 0:
            y, m = y - 1, 12
        yield date(y, m, 1).isoformat(), start.isoformat()


def get(client: httpx.Client, path: str, **params):
    r = client.get(f"{API}/{path}", params=params)
    r.raise_for_status()
    time.sleep(PAUSE_S)
    return r.json().get("data") or []


def save_post(db, sub, p, bucket):
    db.execute(
        """INSERT OR IGNORE INTO posts
           (id, subreddit, title, selftext, permalink, score, num_comments, created_utc, bucket)
           VALUES (?,?,?,?,?,?,?,?,?)""",
        (
            p["id"],
            sub,
            p.get("title", ""),
            (p.get("selftext") or "")[:4000],
            p.get("permalink") or ("https://reddit.com/comments/" + p["id"]),
            p.get("score", 0),
            p.get("num_comments", 0),
            int(p.get("created_utc", 0)),
            bucket,
        ),
    )


def harvest(db, args):
    client = httpx.Client(headers={"User-Agent": UA}, timeout=45, follow_redirects=True)

    for sub in args.subs.split(","):
        for after, before in months(args.years):
            try:
                batch = get(
                    client,
                    "posts/search",
                    subreddit=sub,
                    after=after,
                    before=before,
                    limit=SAMPLE_PER_MONTH,
                    sort="desc",
                )
            except httpx.HTTPStatusError as e:
                print(f"   r/{sub} {after}: {e.response.status_code}", flush=True)
                continue

            top = sorted(batch, key=lambda p: -(p.get("score") or 0))[: args.per_month]
            for p in top:
                save_post(db, sub, p, after[:7])
            db.commit()
            print(f"   r/{sub} {after[:7]}: kept {len(top)}/{len(batch)}", flush=True)

    todo = db.execute(
        "SELECT id FROM posts WHERE comments_fetched = 0 ORDER BY score DESC"
    ).fetchall()
    print(f"== top comments for {len(todo)} posts …", flush=True)

    for i, (post_id,) in enumerate(todo):
        try:
            raw = get(client, "comments/search", link_id=post_id, limit=200)
            good = [
                c
                for c in raw
                if (c.get("body") or "").strip() not in ("", "[deleted]", "[removed]")
                and not c.get("stickied")
            ]
            good.sort(key=lambda c: -(c.get("score") or 0))
            for rank, c in enumerate(good[:COMMENTS_PER_POST], 1):
                db.execute(
                    "INSERT OR IGNORE INTO comments (id, post_id, rank, score, body) VALUES (?,?,?,?,?)",
                    (c["id"], post_id, rank, c.get("score", 0), c["body"][:4000]),
                )
            db.execute("UPDATE posts SET comments_fetched = 1 WHERE id = ?", (post_id,))
        except httpx.HTTPStatusError:
            db.execute("UPDATE posts SET comments_fetched = -1 WHERE id = ?", (post_id,))
        if i % 25 == 0:
            db.commit()
            print(f"   {i}/{len(todo)}", flush=True)


def import_jsonl(db, path):
    n = 0
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        p = json.loads(line)
        pid = p.get("id") or p.get("permalink", str(n)).rstrip("/").split("/")[-1]
        db.execute(
            """INSERT OR REPLACE INTO posts
               (id, subreddit, title, selftext, permalink, score, num_comments, created_utc, bucket, comments_fetched)
               VALUES (?,?,?,?,?,?,?,?,?,1)""",
            (
                pid,
                p.get("subreddit", "imported"),
                p.get("title", ""),
                (p.get("selftext") or "")[:4000],
                p.get("permalink", ""),
                p.get("score", 0),
                p.get("num_comments", 0),
                int(p.get("created_utc", 0)),
                p.get("bucket", "import"),
            ),
        )
        for rank, c in enumerate(p.get("comments", [])[:COMMENTS_PER_POST], 1):
            db.execute(
                "INSERT OR IGNORE INTO comments (id, post_id, rank, score, body) VALUES (?,?,?,?,?)",
                (f"{pid}-{rank}", pid, rank, c.get("score", 0), (c.get("body") or "")[:4000]),
            )
        n += 1
    db.commit()
    print(f"imported {n} posts", flush=True)


def export(db, jsonl_path):
    jsonl = Path(jsonl_path)
    jsonl.parent.mkdir(parents=True, exist_ok=True)
    with jsonl.open("w") as f:
        rows = db.execute(
            "SELECT id, subreddit, title, selftext, permalink, score, num_comments, created_utc, bucket "
            "FROM posts WHERE comments_fetched = 1 ORDER BY subreddit, score DESC"
        )
        for row in rows:
            post = dict(
                zip(
                    "id subreddit title selftext permalink score num_comments created_utc bucket".split(),
                    row,
                )
            )
            post["comments"] = [
                {"rank": r, "score": s, "body": b}
                for r, s, b in db.execute(
                    "SELECT rank, score, body FROM comments WHERE post_id = ? ORDER BY rank",
                    (post["id"],),
                )
            ]
            f.write(json.dumps(post, ensure_ascii=False) + "\n")
    total = db.execute("SELECT count(*) FROM posts WHERE comments_fetched = 1").fetchone()[0]
    print(f"done: {total} seeded prompts → {jsonl}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default="data/seeder/seeder.db")
    parser.add_argument("--jsonl", default="data/seeder/prompts.jsonl")
    parser.add_argument("--import", dest="import_path", help="load a JSONL you pulled yourself")
    parser.add_argument("--years", type=int, default=3)
    parser.add_argument("--per-month", type=int, default=10)
    parser.add_argument("--subs", default=",".join(SUBS))
    args = parser.parse_args()

    db_path = Path(args.db)
    db_path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(db_path)
    db.executescript(SCHEMA)

    if args.import_path:
        import_jsonl(db, args.import_path)
    else:
        harvest(db, args)

    export(db, args.jsonl)
    return 0


if __name__ == "__main__":
    sys.exit(main())
