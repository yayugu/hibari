#!/usr/bin/env python3
"""Download Misskey timeline responses and their media as offline fixtures for the
performance tests (scripts/perf.sh).

Perf builds (the Perf configuration) embed them and render the timelines from these files
without any network access, so that benchmarks run on fixed data.

Everything is stored exactly as the server returned it; resizing for display is the
app's job. Media are keyed by the URL the app requests (see MediaRequestPolicy.swift,
which this script mirrors), so the bundle behaves like a pre-filled HTTP cache.

Output layout (default: perf/Fixtures.bundle, which is git-ignored):

    manifest.json                  timelines, fetch date, instance info, stats
    timelines/<id>/page-NNN.json   raw API responses
    emojis.json                    subset of /api/emojis referenced by the fixtures
    media-index.json               { request URL: "media/<sha1>.<ext>" }
    media/                         raw response bodies

Usage:
    scripts/fetch_fixtures.py                       # local:4 global:2 pages
    scripts/fetch_fixtures.py --timeline local:6
    MISSKEY_TOKEN=xxx scripts/fetch_fixtures.py --timeline home:3 --timeline social:3
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

USER_AGENT = "hibari-fixture-fetcher/0.1"

TIMELINES = {
    "home": ("notes/timeline", "ホーム", True),
    "local": ("notes/local-timeline", "ローカル", False),
    "social": ("notes/hybrid-timeline", "ソーシャル", True),
    "global": ("notes/global-timeline", "グローバル", False),
}

EMOJI_RE = re.compile(r"(?<![a-zA-Z0-9]):([a-zA-Z0-9_+-]+):(?![a-zA-Z0-9])")
REACTION_RE = re.compile(r":([^@:]+)@([^:]+):")


def log(*args):
    print(*args, file=sys.stderr, flush=True)


def api(host, endpoint, body, token=None, retries=3):
    if token:
        body = dict(body, i=token)
    data = json.dumps(body).encode()
    for attempt in range(retries):
        req = urllib.request.Request(
            "https://%s/api/%s" % (host, endpoint),
            data=data,
            headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as res:
                return json.load(res)
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt + 1 < retries:
                time.sleep(5 * (attempt + 1))
                continue
            raise SystemExit("API %s failed: %s %s" % (endpoint, e.code, e.read()[:300]))
    raise SystemExit("API %s failed after retries" % endpoint)


def file_request_url(f):
    """Timeline preview of a drive file. Stills use the web-public original (the app
    downsamples it); GIFs and videos use the server-generated static thumbnail."""
    mime = f.get("type") or ""
    if mime.startswith("image/") and mime != "image/gif":
        return f.get("url") or f.get("thumbnailUrl")
    if mime.startswith("image/") or mime.startswith("video/"):
        return f.get("thumbnailUrl")
    return None


def remote_emoji_request_url(raw_url, media_proxy):
    """Remote custom emojis go through the instance's media proxy (as the official client does)."""
    if not media_proxy or raw_url.startswith(media_proxy + "/"):
        return raw_url
    return "%s/image.webp?%s" % (media_proxy, urllib.parse.urlencode({"url": raw_url, "emoji": "1"}))


def walk_notes(note):
    """Yield the note and every embedded note (renote / reply, recursively)."""
    if not note:
        return
    yield note
    for key in ("renote", "reply"):
        yield from walk_notes(note.get(key))


def collect(notes, media_proxy):
    """Return (request urls, local emoji names) referenced by the notes."""
    urls = set()
    local_emojis = set()

    def add(url):
        if url:
            urls.add(url)

    def add_remote_emoji(raw_url):
        if raw_url:
            urls.add(remote_emoji_request_url(raw_url, media_proxy))

    for top in notes:
        for note in walk_notes(top):
            user = note.get("user") or {}
            is_remote = user.get("host") is not None
            add(user.get("avatarUrl"))

            for f in note.get("files") or []:
                add(file_request_url(f))

            texts = [note.get("text") or "", note.get("cw") or ""]
            poll = note.get("poll") or {}
            texts += [c.get("text") or "" for c in poll.get("choices") or []]
            for source, emoji_map in (("\n".join(texts), note.get("emojis") or {}),
                                      (user.get("name") or "", user.get("emojis") or {})):
                for name in EMOJI_RE.findall(source):
                    if is_remote:
                        add_remote_emoji(emoji_map.get(name))
                    else:
                        local_emojis.add(name)

            reaction_emojis = note.get("reactionEmojis") or {}
            for reaction in (note.get("reactions") or {}).keys():
                m = REACTION_RE.fullmatch(reaction)
                if not m:
                    continue
                name, host = m.groups()
                if host == ".":
                    local_emojis.add(name)
                else:
                    add_remote_emoji(reaction_emojis.get("%s@%s" % (name, host)))
    return urls, local_emojis


def sniff_ext(head):
    if head.startswith(b"\x89PNG"):
        return "png"
    if head.startswith(b"GIF8"):
        return "gif"
    if head.startswith(b"\xff\xd8"):
        return "jpg"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "webp"
    if head[4:12] in (b"ftypavif", b"ftypavis"):
        return "avif"
    if head[4:12] in (b"ftypheic", b"ftypmif1"):
        return "heic"
    return "bin"


def download(url, media_dir, retries=3):
    """Returns (url, file name or None, bytes). The body is stored untouched.

    Uses the system curl: the stock macOS Python links an old LibreSSL that cannot
    talk to TLS 1.3-only servers (several remote instances behind the media proxy).
    """
    tmp = os.path.join(media_dir, ".%s.part" % hashlib.sha1(url.encode()).hexdigest())
    for attempt in range(retries):
        result = subprocess.run(
            ["curl", "-sSfL", "--max-time", "120", "-A", USER_AGENT, "-o", tmp, url],
            capture_output=True, text=True)
        if result.returncode == 0:
            with open(tmp, "rb") as f:
                head = f.read(16)
            name = "%s.%s" % (hashlib.sha1(url.encode()).hexdigest(), sniff_ext(head))
            os.rename(tmp, os.path.join(media_dir, name))
            return url, name, os.path.getsize(os.path.join(media_dir, name))
        if attempt + 1 == retries or "404" in result.stderr:
            log("  ! failed %s: %s" % (url, result.stderr.strip()))
            if os.path.exists(tmp):
                os.remove(tmp)
            return url, None, 0
        time.sleep(1 + attempt)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="misskey.io")
    parser.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "perf", "Fixtures.bundle"))
    parser.add_argument("--timeline", action="append", metavar="ID:PAGES",
                        help="timeline to fetch (home, local, social, global). default: local:4 global:2")
    parser.add_argument("--limit", type=int, default=100, help="notes per page (max 100)")
    parser.add_argument("--jobs", type=int, default=8, help="parallel media downloads")
    args = parser.parse_args()

    token = os.environ.get("MISSKEY_TOKEN")
    specs = args.timeline or ["local:4", "global:2"]
    out = os.path.abspath(args.out)
    if os.path.exists(out):
        shutil.rmtree(out)
    media_dir = os.path.join(out, "media")
    os.makedirs(media_dir)

    meta = api(args.host, "meta", {"detail": False})
    media_proxy = meta.get("mediaProxy")

    manifest_timelines = []
    all_notes = []
    for spec in specs:
        tl_id, _, pages = spec.partition(":")
        if tl_id not in TIMELINES:
            raise SystemExit("unknown timeline: %s" % tl_id)
        endpoint, title, needs_auth = TIMELINES[tl_id]
        if needs_auth and not token:
            raise SystemExit("%s timeline needs MISSKEY_TOKEN" % tl_id)
        os.makedirs(os.path.join(out, "timelines", tl_id))
        page_files = []
        until_id = None
        for page in range(int(pages or 1)):
            body = {"limit": args.limit}
            if until_id:
                body["untilId"] = until_id
            notes = api(args.host, endpoint, body, token if needs_auth else None)
            if not notes:
                break
            rel = "timelines/%s/page-%03d.json" % (tl_id, page)
            with open(os.path.join(out, rel), "w") as f:
                json.dump(notes, f, ensure_ascii=False)
            page_files.append(rel)
            all_notes += notes
            until_id = notes[-1]["id"]
            log("%s page %d: %d notes" % (tl_id, page, len(notes)))
            time.sleep(1)
        manifest_timelines.append({"id": tl_id, "title": title, "endpoint": endpoint, "pages": page_files})

    urls, local_emoji_names = collect(all_notes, media_proxy)

    log("fetching emoji list...")
    emoji_list = api(args.host, "emojis", {}).get("emojis", [])
    emojis = [e for e in emoji_list if e["name"] in local_emoji_names]
    with open(os.path.join(out, "emojis.json"), "w") as f:
        json.dump({"emojis": emojis}, f, ensure_ascii=False)
    urls.update(e["url"] for e in emojis)

    log("downloading %d media files..." % len(urls))
    index = {}
    total = 0
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(download, u, media_dir) for u in sorted(urls)]
        for i, fut in enumerate(futures, 1):
            url, name, size = fut.result()
            if name:
                index[url] = "media/" + name
                total += size
            if i % 200 == 0:
                log("  %d/%d" % (i, len(urls)))

    with open(os.path.join(out, "media-index.json"), "w") as f:
        json.dump(index, f, ensure_ascii=False, indent=0, sort_keys=True)

    manifest = {
        "host": args.host,
        "mediaProxy": media_proxy,
        "fetchedAt": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
        "timelines": manifest_timelines,
        "emojis": "emojis.json",
        "mediaIndex": "media-index.json",
        "stats": {"notes": len(all_notes), "media": len(index), "mediaBytes": total,
                  "failedMedia": len(urls) - len(index)},
    }
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    log("done: %d notes, %d media (%.1f MB) -> %s" % (len(all_notes), len(index), total / 1048576, out))


if __name__ == "__main__":
    main()
