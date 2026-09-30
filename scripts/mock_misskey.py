#!/usr/bin/env python3
"""A fake Misskey server for trying the sign-in flow and the timelines without a real
account. scripts/test_ui.py starts a fresh instance for each UI test run.

Everything it serves is made up: users, notes (MFM, custom emojis, images, CW, polls,
renotes, quotes, replies, reactions), avatars, images and custom emojis (generated PNGs).
The MiAuth page has "approve" buttons instead of a real sign-in: one for each of the two
accounts (@hibari_mock and @hibari_sub, for trying account switching).

    scripts/mock_misskey.py                 # kernel-assigned port, printed on startup
    scripts/mock_misskey.py --port 9000 --latency 0.5

Enter the printed URL as the server on the sign-in screen (Simulator).
Tokens it hands out stay valid across restarts, so a simulator signed in to it stays so.

The post screen's endpoints (notes/show, notes/conversation, notes/replies) and reactions
(notes/reactions/create, notes/reactions/delete) work too; reactions stay until a restart.
Some notes have made-up reply threads that are not in the timelines.

So does the profile screen: users/show, users/notes, users/featured-notes, and following,
muting and blocking (following/*, mute/*, renote-mute/*, blocking/*), which also stay until
a restart. @user08 is locked (follows become requests), @user02 follows the accounts.

And posting: notes/create (notes, replies, quotes, renotes; on top of every timeline),
notes/delete (the account's own notes) and drive/files/create (multipart; the files are
served back from /upload/<id>), until a restart. Texts over 3000 characters are refused like Misskey does.

And the notifications: i/notifications-grouped (reactions and renotes grouped like
Misskey's; reading them marks them read), notes/mentions and the unread count in `i`.
Each account starts with a few unread ones.

Other pages:
    /control/post      puts N new notes (dated now) on top of every timeline (?n=3), to try
                       pull-to-refresh; with image=N each has a short text and N images;
                       with user=u08 they are that user's. Returns their ids ("ids")
    /control/notify    N new unread notifications (reactions) for an account (?n=2&account=sub;
                       the account is "me" by default)
    /control/fail      the next N timeline requests fail with 500 (?n=3)
    /control/revoke    makes every issued token invalid (the app should ask to sign in again)
"""

import argparse
import datetime
import html
import json
import random
import struct
import sys
import threading
import time
import urllib.parse
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

def account(user_id, username, name, following, followers):
    return {
        "id": user_id,
        "username": username,
        "name": name,
        "host": None,
        "avatarUrl": None,
        "avatarBlurhash": None,
        "isBot": False,
        "isCat": False,
        "emojis": {},
        "policies": {"ltlAvailable": True, "gtlAvailable": True},
        "followingCount": following,
        "followersCount": followers,
    }


ME = account("mockuser", "hibari_mock", "Hibari テスト", 6, 128)
SUB = account("mocksub", "hibari_sub", "サブ :blobcat:", 2, 3)
ACCOUNTS = {"me": ME, "sub": SUB}

TIMELINES = ("notes/timeline", "notes/featured", "notes/local-timeline", "notes/hybrid-timeline",
             "notes/global-timeline")

state = {
    "approved": {},
    "generation": 0,
    "fail": 0,
    "posted": 0,
    "relations": {},
    "uploads": {},
    "created": 0,
    "notifications": {},
    "unread": {},
    "notified": 0,
    "favorites": {},
    "favorited": 0,
}

MAX_NOTE_TEXT_LENGTH = 3000

FOLLOWED = (0, 1, 2, 3, 6, 7)
FOLLOWERS = (2,)
LOCKED = (8,)
lock = threading.Lock()


def png(width, height, rgb):
    """A PNG of the given size: `rgb` fading darker towards the bottom."""
    r, g, b = rgb
    rows = bytearray()
    for y in range(height):
        f = 1 - 0.35 * y / max(1, height - 1)
        rows += b"\x00" + bytes((int(r * f), int(g * f), int(b * f))) * width

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(rows), 6))
            + chunk(b"IEND", b""))


def color(seed):
    rng = random.Random(seed)
    return tuple(rng.randint(60, 230) for _ in range(3))


png_cache = {}


def media(path, query):
    """`/media/<kind>/<name>.png?w=..&h=..`: a PNG whose color follows the name."""
    width = min(2000, max(1, int(query.get("w", ["256"])[0])))
    height = min(2000, max(1, int(query.get("h", ["256"])[0])))
    key = (path, width, height)
    with lock:
        cached = png_cache.get(key)
    if cached is None:
        cached = png(width, height, color(path))
        with lock:
            if len(png_cache) > 400:
                png_cache.clear()
            png_cache[key] = cached
    return cached


EMOJIS = [("blobcat", 128, 128), ("hibari_wide", 384, 96), ("tall_bird", 96, 160), ("ok", 128, 128)]

TEXTS = [
    "おはようございます☀️",
    "今日はいい天気ですね。散歩に行ってきます",
    "**太字** と <i>斜体</i> と ~~取り消し~~ と <small>小さい文字</small>",
    "ハッシュタグ #hibari とメンション @hibari_mock とリンク https://misskey-hub.net/ja/docs/ と [名前付きリンク](https://example.com)",
    "$[x2 大きい文字] と $[spin くるくる] と $[fg.color=f80 色]",
    "カスタム絵文字 :blobcat: :hibari_wide: :tall_bird: を使ってみる",
    "\n".join("%d行目のテキスト" % i for i in range(1, 16)),
    "Hello from the mock server! This is a longer English sentence to check how the text wraps over several lines.",
    "<center>中央寄せのテキスト</center>",
    "> 引用された文章\nそれに対する返事",
    "`inline code` と\n```\nlet code = \"block\"\n```",
    "🐦🐦🐦",
    "吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。",
    "ｗ",
    "Misskey のテスト用サーバーです :ok:",
]

POLL = [["たけのこ", "きのこ", "どちらでもない"], ["はい", "いいえ"]]
REACTIONS = ["👍", "❤", "😆", "🎉", ":blobcat@.:", ":ok@.:", ":hibari_wide@.:", ":remote_ai@remote.example:"]
ASPECTS = [(1600, 1200), (1200, 1600), (1920, 1080), (1000, 1000), (800, 2000)]


def build(base, count=300, seed=1):
    """Users, the local emoji list, notes (newest first) and replies that are not in any
    timeline (by the id of the note they answer)."""
    rng = random.Random(seed)
    emojis = [{"name": name, "url": "%s/media/emoji/%s.png?w=%d&h=%d" % (base, name, w, h), "aliases": [],
               "category": "mock"} for name, w, h in EMOJIS]
    names = ["ひばり", "すずめ :blobcat:", "Tsubame", "メジロ", "しじゅうから", "とても長い名前のユーザーです :hibari_wide: ほんとうに長い",
             "Crow", "うぐいす", "カワセミ", "Robin", "ふくろう", "つぐみ"]
    users = []
    for i, name in enumerate(names):
        remote = i in (6, 9)
        users.append({
            "id": "u%02d" % i,
            "username": "user%02d" % i,
            "name": name,
            "host": "remote.example" if remote else None,
            "avatarUrl": "%s/media/avatar/u%02d.png?w=400&h=400" % (base, i),
            "avatarBlurhash": None,
            "isBot": i == 4,
            "isCat": i == 1,
            "emojis": {"remote_ai": "%s/media/emoji/remote_ai.png?w=128&h=128" % base} if remote else {},
        })

    now = datetime.datetime.now(datetime.timezone.utc)
    notes = []
    for i in range(count):
        created = now - datetime.timedelta(seconds=90 * (count - i) + rng.randint(0, 60))
        note = make_note(base, rng, "n%05d" % i, created, rng.choice(users), notes)
        notes.append(note)
    notes.reverse()
    return users, emojis, notes, thread_replies(base, rng, notes, users, now)


REPLY_TEXTS = ["わかる", "それな〜", "ありがとうございます！", "すごい :blobcat:", "えっ、本当ですか？",
               "今日もおつかれさまです", "Nice! 👍", "あとで見ます", "ｗｗｗ", "これは良い"]


def thread_replies(base, rng, notes, users, now):
    """Replies to some of the newest notes, a few of them answering each other."""
    replies = []
    for note in notes[:120]:
        if note.get("text") is None or rng.random() < 0.6:
            continue
        created = parse_time(note["createdAt"])
        parent = note
        for k in range(rng.randint(1, 6)):
            target = parent if replies and parent is not note and rng.random() < 0.3 else note
            created = min(now, created + datetime.timedelta(seconds=rng.randint(20, 900)))
            reply = make_note(base, rng, "%sr%02d" % (target["id"], k), created, rng.choice(users), [])
            reply.update(text=rng.choice(REPLY_TEXTS), cw=None, renoteId=None, renote=None, poll=None,
                         replyId=target["id"], reply=target)
            replies.append(reply)
            parent = reply
    return replies


def iso(time):
    return time.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def lite(user):
    return {k: user[k] for k in ("id", "username", "name", "host", "avatarUrl", "avatarBlurhash", "isBot", "isCat",
                                 "emojis")}


def build_notifications(base, account, users, notes, by_id, now, older=40):
    """The account's notifications, newest first, and the notes they need (by id): notes of
    the account's that others reacted to, renoted, replied to and quoted, and mentions."""
    rng = random.Random(account["id"])
    tag = 1 if account is ME else 2
    me = lite(account)
    made = {}
    serial = [0]

    def at(minutes):
        return now - datetime.timedelta(minutes=minutes)

    def own(text, minutes):
        serial[0] += 1
        note = make_note(base, rng, "zn%d%03d" % (tag, serial[0]), at(minutes), me, [])
        note.update(text=text, cw=None, renoteId=None, renote=None, replyId=None, reply=None, poll=None, files=[],
                    reactions={}, reactionEmojis={})
        made[note["id"]] = note
        return note

    def by(user, minutes, **fields):
        serial[0] += 1
        note = make_note(base, rng, "zn%d%03d" % (tag, serial[0]), at(minutes), user, [])
        note.update(cw=None, renoteId=None, renote=None, replyId=None, reply=None, poll=None, files=[], reactions={},
                    reactionEmojis={})
        note.update(fields)
        made[note["id"]] = note
        return note

    counter = [1000]

    def entry(kind, minutes, **fields):
        counter[0] -= 1
        item = {"id": "nt%d%04d" % (tag, counter[0]), "createdAt": iso(at(minutes)), "type": kind}
        item.update(fields)
        return item

    first = own("通知のテスト用のノート :blobcat:", 90)
    second = own("二つめのノート。画像なし", 300)
    poll = own("どっちが好き？", 600)
    poll["poll"] = {"multiple": False, "expiresAt": iso(at(5)),
                    "choices": [{"text": "たけのこ", "votes": 3, "isVoted": False}, {"text": "きのこ", "votes": 2, "isVoted": True}]}
    reactions = ["👍", ":blobcat@.:", "❤", "🎉", ":hibari_wide@.:"]
    for user, reaction in zip(users, reactions):
        first["reactions"][reaction] = first["reactions"].get(reaction, 0) + 1
    renote = by(users[2], 20, text=None, renoteId=first["id"], renote=first)
    first["renoteCount"] = 2
    reply = by(users[1], 3, text="いいですね！ :blobcat:", replyId=first["id"], reply=first)
    quote = by(users[7], 45, text="これ見て", renoteId=second["id"], renote=second)
    mention = by(users[6], 60, text="@%s こんにちは" % account["username"])
    items = [
        entry("reaction:grouped", 1, note=first,
              reactions=[{"user": u, "reaction": r} for u, r in zip(users[:5], reactions)]),
        entry("reply", 3, userId=users[1]["id"], user=users[1], note=reply),
        entry("follow", 10, userId=users[3]["id"], user=users[3]),
        entry("renote:grouped", 20, note=renote, users=[users[2], users[5]]),
        entry("quote", 45, userId=users[7]["id"], user=users[7], note=quote),
        entry("mention", 60, userId=users[6]["id"], user=users[6], note=mention),
        entry("reaction", 120, userId=users[8]["id"], user=users[8], note=second, reaction=":blobcat@.:"),
        entry("pollEnded", 180, note=poll),
        entry("followRequestAccepted", 240, userId=users[8]["id"], user=users[8], message=None),
        entry("achievementEarned", 400, achievement="notes1"),
        entry("login", 500),
        entry("someFutureType", 510),
    ]
    for index in range(older):
        user = users[index % len(users)]
        minutes = 600 + index * 30
        if index % 3 == 0:
            items.append(entry("follow", minutes, userId=user["id"], user=user))
        else:
            items.append(entry("reaction", minutes, userId=user["id"], user=user, note=second,
                               reaction=rng.choice(["👍", "❤", ":ok@.:"])))
    by_id.update(made)
    return items


def parse_time(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def make_note(base, rng, note_id, created, user, older, images=0):
    note = {
        "id": note_id,
        "createdAt": created.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "userId": user["id"],
        "user": user,
        "text": rng.choice(TEXTS),
        "cw": None,
        "visibility": "public",
        "localOnly": False,
        "renoteCount": rng.choice([0, 0, 0, 1, 3, 12]),
        "repliesCount": rng.choice([0, 0, 1, 2]),
        "reactions": {},
        "reactionEmojis": {},
        "emojis": {},
        "files": [],
        "replyId": None,
        "renoteId": None,
    }
    if images:
        note["text"] = "画像つきのノート"
        note["files"] = []
        for k in range(images):
            w, h = ((1600, 900), (900, 1600), (1200, 1200))[k % 3]
            url = "%s/media/file/%s-%d.png?w=%d&h=%d" % (base, note_id, k, w, h)
            note["files"].append({
                "id": "%s-%d" % (note_id, k), "type": "image/png", "name": "%s-%d.png" % (note_id, k), "size": w * h,
                "isSensitive": False, "blurhash": None, "properties": {"width": w, "height": h}, "url": url,
                "thumbnailUrl": url, "comment": "テスト画像 %d" % (k + 1),
            })
        return note
    n = int(note_id.lstrip("nz").split("r")[0] or 0)
    if user["host"]:
        note["emojis"] = user["emojis"]
        note["text"] = note["text"].replace(":blobcat:", ":remote_ai:")
    targets = [t for t in older[-60:] if t.get("text") is not None][-40:]
    if targets and n % 7 == 3:
        target = rng.choice(targets)
        note.update(text=None, renoteId=target["id"], renote=target)
        return note
    if targets and n % 11 == 5:
        target = rng.choice(targets)
        note.update(renoteId=target["id"], renote=target)
    if targets and n % 13 == 8:
        target = rng.choice(targets)
        note.update(replyId=target["id"], reply=target)
    if n % 9 == 4:
        note["cw"] = "ネタバレ注意"
    if n % 5 == 1:
        count = rng.choice([1, 1, 2, 3, 4, 5])
        sensitive = rng.random() < 0.2
        note["files"] = [image(base, "%s-%d" % (note_id, k), rng, sensitive) for k in range(count)]
    if n % 17 == 2:
        note["files"] = [{
            "id": "%s-video" % note_id, "type": "video/mp4", "name": "video.mp4", "size": 1000000,
            "isSensitive": False, "blurhash": None, "properties": {"width": 1280, "height": 720},
            "url": "%s/media/file/%s.mp4" % (base, note_id),
            "thumbnailUrl": "%s/media/thumb/%s.png?w=498&h=280" % (base, note_id), "comment": None,
        }]
    if n % 19 == 6:
        choices = rng.choice(POLL)
        note["poll"] = {"multiple": False, "expiresAt": None,
                        "choices": [{"text": c, "votes": rng.randint(0, 40), "isVoted": False} for c in choices]}
    for key in rng.sample(REACTIONS, rng.choice([0, 0, 1, 2, 4, 7])):
        note["reactions"][key] = rng.randint(1, 60)
        if key.endswith("@remote.example:"):
            note["reactionEmojis"]["remote_ai@remote.example"] = "%s/media/emoji/remote_ai.png?w=128&h=128" % base
    return note


def image(base, file_id, rng, sensitive):
    w, h = rng.choice(ASPECTS)
    url = "%s/media/file/%s.png?w=%d&h=%d" % (base, file_id, w, h)
    return {
        "id": file_id, "type": "image/png", "name": "%s.png" % file_id, "size": w * h, "isSensitive": sensitive,
        "blurhash": None, "properties": {"width": w, "height": h}, "url": url,
        "thumbnailUrl": "%s/media/file/%s.png?w=%d&h=%d" % (base, file_id, 498, int(498 * h / w)), "comment": None,
    }


PAGE = """<!doctype html>
<html lang="ja"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
  body {{ font: 17px -apple-system, sans-serif; margin: 32px 24px; color: #0f1419; }}
  h1 {{ font-size: 24px; }}
  button {{ font-size: 17px; font-weight: 600; padding: 14px 0; width: 100%; border-radius: 999px; border: 0; margin-top: 12px; }}
  .approve {{ background: #1d9bf0; color: white; }}
  .deny {{ background: #eff3f4; color: #0f1419; }}
</style></head>
<body>{body}</body></html>"""


def page(title, body):
    return PAGE.format(title=html.escape(title), body=body).encode()


class Handler(BaseHTTPRequestHandler):
    base = ""
    users = []
    emojis = []
    timelines = {}
    by_id = {}
    latency = 0.0

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.command, fmt % args))

    def send(self, status, body, content_type="application/json; charset=utf-8"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def api_error(self, status, code, message):
        self.send(status, {"error": {"code": code, "message": message, "id": "mock", "kind": "client"}})


    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(url.query)
        parts = [p for p in url.path.split("/") if p]
        if parts[:1] == ["media"] and url.path.endswith(".png"):
            return self.send(200, media(url.path, query), "image/png")
        if parts[:1] == ["miauth"] and len(parts) == 2:
            return self.miauth_page(parts[1], query)
        if parts[:1] == ["miauth-approve"] and len(parts) == 2:
            return self.miauth_approve(parts[1], query)
        if parts == ["control", "post"]:
            count = int(query.get("n", ["1"])[0])
            ids = self.post(count, images=int(query.get("image", ["0"])[0]), user_id=query.get("user", [None])[0])
            return self.send(200, {"posted": len(ids), "ids": ids})
        if parts == ["control", "notify"]:
            account = ACCOUNTS.get(query.get("account", ["me"])[0], ME)
            return self.send(200, {"notified": self.notify(account, int(query.get("n", ["1"])[0]))})
        if parts == ["control", "fail"]:
            with lock:
                state["fail"] = int(query.get("n", ["1"])[0])
            return self.send(200, {"fail": state["fail"]})
        if parts == ["control", "revoke"]:
            with lock:
                state["generation"] += 1
            return self.send(200, {"revoked": True})
        if parts == ["api", "emojis"]:
            return self.send(200, {"emojis": self.emojis})
        if parts[:1] == ["upload"] and len(parts) == 2:
            with lock:
                upload = state["uploads"].get(parts[1])
            if upload:
                return self.send(200, upload[1], upload[0])
        self.send(404, page("Not found", "<h1>404</h1>"), "text/html; charset=utf-8")

    def post(self, count, images=0, user_id=None):
        rng = random.Random()
        now = datetime.datetime.now(datetime.timezone.utc)
        with lock:
            start = state["posted"]
            state["posted"] += count
        author = next((u for u in self.users if u["id"] == user_id), None)
        ids = []
        for index in range(start, start + count):
            note = make_note(self.base, rng, "z%05d" % index, now, author or rng.choice(self.users), [], images)
            note["repliesCount"] = 0
            with lock:
                self.by_id[note["id"]] = note
                for endpoint, notes in self.timelines.items():
                    if endpoint != "notes/featured":
                        notes.insert(0, note)
            ids.append(note["id"])
        return ids

    def notify(self, account, count):
        """Reactions to the account's newest note, unread."""
        now = iso(datetime.datetime.now(datetime.timezone.utc))
        with lock:
            items = state["notifications"][account["id"]]
            note = next(n["note"] for n in items if n.get("note") and n["note"]["userId"] == account["id"])
            for _ in range(count):
                state["notified"] += 1
                user = self.users[state["notified"] % len(self.users)]
                items.insert(0, {"id": "nz%05d" % state["notified"], "createdAt": now, "type": "reaction",
                                 "userId": user["id"], "user": user, "note": note, "reaction": "🎉"})
            state["unread"][account["id"]] += count
            return state["unread"][account["id"]]

    def miauth_page(self, session, query):
        name = query.get("name", ["?"])[0]
        permissions = query.get("permission", [""])[0].split(",")
        callback = query.get("callback", [""])[0]
        def approve(user):
            return "/miauth-approve/%s?%s" % (session, urllib.parse.urlencode({"callback": callback, "user": user}))
        items = "".join("<li>%s</li>" % html.escape(p) for p in permissions if p)
        body = (
            "<h1>%s にアクセスを許可しますか？</h1>" % html.escape(name)
            + "<p>(mock) @%s としてログインしています</p>" % ME["username"]
            + "<details><summary>権限 (%d)</summary><ul>%s</ul></details>" % (len(permissions), items)
            + "<a href='%s'><button class='approve'>許可</button></a>" % html.escape(approve("me"))
            + "<a href='%s'><button class='approve'>@%s として許可</button></a>"
            % (html.escape(approve("sub")), SUB["username"])
            + "<button class='deny' onclick=\"document.body.innerHTML='<h1>拒否しました</h1>'\">拒否</button>"
        )
        self.send(200, page("MiAuth", body), "text/html; charset=utf-8")

    def miauth_approve(self, session, query):
        user = query.get("user", ["me"])[0]
        with lock:
            state["approved"][session] = user if user in ACCOUNTS else "me"
        callback = query.get("callback", [""])[0]
        if callback:
            separator = "&" if "?" in callback else "?"
            self.send_response(302)
            self.send_header("Location", "%s%ssession=%s" % (callback, separator, session))
            self.end_headers()
        else:
            self.send(200, page("MiAuth", "<h1>許可しました</h1>"), "text/html; charset=utf-8")


    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        content_type = self.headers.get("Content-Type") or ""
        files = {}
        if content_type.startswith("multipart/form-data"):
            body, files = parse_multipart(raw, content_type)
        else:
            try:
                body = json.loads(raw or b"{}")
            except ValueError:
                return self.api_error(400, "INVALID_PARAM", "invalid JSON")
        if self.latency:
            time.sleep(self.latency)
        endpoint = urllib.parse.urlparse(self.path).path
        if not endpoint.startswith("/api/"):
            return self.api_error(404, "NO_SUCH_ENDPOINT", "no such endpoint")
        endpoint = endpoint[len("/api/"):]

        if endpoint == "meta":
            meta = {"name": "Mock Misskey", "uri": self.base, "version": "2025.4.1-mock", "iconUrl": None,
                    "mediaProxy": None, "maxNoteTextLength": MAX_NOTE_TEXT_LENGTH}
            if body.get("detail", True):
                meta["features"] = {"miauth": True, "localTimeline": True, "globalTimeline": True}
            return self.send(200, meta)
        if endpoint == "emojis":
            return self.send(200, {"emojis": self.emojis})
        if endpoint.startswith("miauth/") and endpoint.endswith("/check"):
            session = endpoint.split("/")[1]
            with lock:
                user = state["approved"].pop(session, None)
                token = "mock-%d-%s%s" % (state["generation"], "sub." if user == "sub" else "", session)
            if user is None:
                return self.send(200, {"ok": False})
            return self.send(200, {"ok": True, "token": token, "user": ACCOUNTS[user]})

        token = str(body.get("i", ""))
        with lock:
            prefix = "mock-%d-" % state["generation"]
        if not token.startswith(prefix):
            return self.api_error(401, "AUTHENTICATION_FAILED", "Authentication failed. Please ensure your token is correct.")
        me = SUB if token[len(prefix):].startswith("sub.") else ME

        if endpoint == "i":
            with lock:
                unread = state["unread"][me["id"]]
            return self.send(200, dict(me, hasUnreadNotification=unread > 0, unreadNotificationsCount=unread))
        if endpoint == "i/notifications-grouped":
            with lock:
                items = list(state["notifications"][me["id"]])
                if body.get("markAsRead", True):
                    state["unread"][me["id"]] = 0
            until = body.get("untilId")
            if until:
                items = [n for n in items if n["id"] < until]
            return self.send(200, items[:min(100, int(body.get("limit") or 10))])
        if endpoint == "notifications/mark-all-as-read":
            with lock:
                state["unread"][me["id"]] = 0
            return self.send(204, b"")
        if endpoint == "notes/mentions":
            mention = "@%s" % me["username"]
            with lock:
                notes = sorted((n for n in self.by_id.values() if mention in (n.get("text") or "")),
                               key=lambda n: n["id"], reverse=True)
            until = body.get("untilId")
            if until:
                notes = [n for n in notes if n["id"] < until]
            return self.send(200, notes[:min(100, int(body.get("limit") or 10))])
        if endpoint in TIMELINES:
            with lock:
                if state["fail"] > 0:
                    state["fail"] -= 1
                    return self.api_error(500, "INTERNAL_ERROR", "Internal error occurred.")
                notes = list(self.timelines[endpoint])
            limit = min(100, int(body.get("limit") or 10))
            until = body.get("untilId")
            if until:
                notes = [n for n in notes if n["id"] < until]
            return self.send(200, notes[:limit])
        if endpoint == "drive/files/create":
            return self.upload(body, files)
        if endpoint in ("notes/search", "notes/search-by-tag", "users/search", "hashtags/trend"):
            return self.search(endpoint, body, me)
        if endpoint == "notes/create":
            return self.create_note(body, me)
        if endpoint == "notes/delete":
            return self.delete_note(body, me)
        if endpoint in ("i/favorites", "notes/favorites/create", "notes/favorites/delete", "notes/state"):
            return self.favorite_endpoint(endpoint, body, me)
        if endpoint.startswith("notes/"):
            return self.note_endpoint(endpoint, body)
        if endpoint.startswith(("users/", "following/", "mute/", "renote-mute/", "blocking/")):
            return self.user_endpoint(endpoint, body, me)
        self.api_error(400, "NO_SUCH_ENDPOINT", "not mocked: %s" % endpoint)


    def upload(self, body, files):
        upload = files.get("file")
        if upload is None:
            return self.api_error(400, "INVALID_PARAM", "file is required")
        filename, file_type, data = upload
        width, height = image_size(data)
        with lock:
            file_id = "f%05d" % len(state["uploads"])
            state["uploads"][file_id] = (file_type, data)
        url = "%s/upload/%s" % (self.base, file_id)
        return self.send(200, {
            "id": file_id, "type": file_type, "name": body.get("name") or filename, "size": len(data),
            "isSensitive": False, "blurhash": None,
            "properties": {"width": width, "height": height} if width else {},
            "url": url, "thumbnailUrl": url, "comment": None,
        })

    def create_note(self, body, me):
        text = body.get("text")
        text = text.strip() if isinstance(text, str) else None
        if isinstance(body.get("text"), str) and len(body["text"]) > MAX_NOTE_TEXT_LENGTH:
            return self.api_error(400, "INVALID_PARAM", "Invalid param.")
        with lock:
            files = []
            for file_id in body.get("fileIds") or []:
                if file_id not in state["uploads"]:
                    return self.api_error(400, "NO_SUCH_FILE", "Some files are not found.")
                file_type, data = state["uploads"][file_id]
                width, height = image_size(data)
                url = "%s/upload/%s" % (self.base, file_id)
                files.append({
                    "id": file_id, "type": file_type, "name": file_id, "size": len(data), "isSensitive": False,
                    "blurhash": None, "properties": {"width": width, "height": height} if width else {},
                    "url": url, "thumbnailUrl": url, "comment": None,
                })
            reply = self.by_id.get(body.get("replyId")) if body.get("replyId") else None
            renote = self.by_id.get(body.get("renoteId")) if body.get("renoteId") else None
            if (body.get("replyId") and reply is None) or (body.get("renoteId") and renote is None):
                return self.api_error(400, "NO_SUCH_NOTE", "No such note.")
            if not text and not files and renote is None:
                return self.api_error(400, "INVALID_PARAM", "Invalid param.")
            state["created"] += 1
            note_id = "zz%05d" % state["created"]
        user = {k: me[k] for k in ("id", "username", "name", "host", "avatarUrl", "avatarBlurhash", "isBot", "isCat",
                                   "emojis")}
        note = {
            "id": note_id,
            "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds")
                                 .replace("+00:00", "Z"),
            "userId": me["id"], "user": user, "text": text or None, "cw": None,
            "visibility": body.get("visibility") or "public", "localOnly": False,
            "renoteCount": 0, "repliesCount": 0, "reactions": {}, "reactionEmojis": {}, "emojis": {},
            "files": files, "replyId": reply["id"] if reply else None, "renoteId": renote["id"] if renote else None,
        }
        if reply:
            note["reply"] = reply
        if renote:
            note["renote"] = renote
        with lock:
            if reply:
                reply["repliesCount"] = reply.get("repliesCount", 0) + 1
            if renote:
                renote["renoteCount"] = renote.get("renoteCount", 0) + 1
            self.by_id[note_id] = note
            for endpoint, notes in self.timelines.items():
                if endpoint != "notes/featured":
                    notes.insert(0, note)
        return self.send(200, {"createdNote": note})

    def delete_note(self, body, me):
        with lock:
            note = self.by_id.get(body.get("noteId"))
            if note is None:
                return self.api_error(400, "NO_SUCH_NOTE", "No such note.")
            if note["userId"] != me["id"]:
                return self.api_error(400, "ACCESS_DENIED", "Access denied.")
            del self.by_id[note["id"]]
            for notes in self.timelines.values():
                notes[:] = [n for n in notes if n["id"] != note["id"]]
            if note.get("renote"):
                note["renote"]["renoteCount"] = max(0, note["renote"].get("renoteCount", 0) - 1)
        return self.send(204, b"")


    def find_user(self, body):
        everyone = self.users + list(ACCOUNTS.values())
        if body.get("userId"):
            return next((u for u in everyone if u["id"] == body["userId"]), None)
        username = str(body.get("username", "")).lower()
        host = body.get("host") or None
        return next((u for u in everyone if u["username"].lower() == username and u["host"] == host), None)

    def relation(self, me, user):
        """The (mutable) relation of the account `me` to `user`."""
        key = (me["id"], user["id"])
        with lock:
            if key not in state["relations"]:
                index = int(user["id"][1:]) if user["id"][1:].isdigit() else -1
                state["relations"][key] = {
                    "isFollowing": index in FOLLOWED, "isFollowed": index in FOLLOWERS,
                    "hasPendingFollowRequestFromYou": False, "hasPendingFollowRequestToYou": False,
                    "isBlocking": False, "isBlocked": False, "isMuted": False, "isRenoteMuted": False,
                    "withReplies": False, "notify": "none",
                }
            return state["relations"][key]

    def detailed(self, me, user):
        index = int(user["id"][1:]) if user["id"][1:].isdigit() else 0
        rng = random.Random(user["id"])
        detail = dict(user)
        detail.update({
            "bannerUrl": "%s/media/banner/%s.png?w=1500&h=500" % (self.base, user["id"]),
            "bannerBlurhash": None,
            "description": "%s のプロフィールです :blobcat:\n好きなもの: #hibari と @user00 と https://misskey-hub.net/"
                           % user["name"],
            "location": "日本" if index % 2 == 0 else None,
            "birthday": "2000-0%d-1%d" % (index % 9 + 1, index % 9) if index % 3 == 0 else None,
            "createdAt": "2023-0%d-15T12:00:00.000Z" % (index % 9 + 1),
            "fields": [{"name": "Web", "value": "https://example.com/%s" % user["username"]},
                       {"name": "好きな鳥", "value": "ひばり :blobcat:"}] if index % 2 == 0 else [],
            "verifiedLinks": ["https://example.com/%s" % user["username"]] if index == 0 else [],
            "followingCount": rng.randint(0, 500), "followersCount": rng.randint(0, 5000),
            "notesCount": sum(1 for n in self.by_id.values() if n["userId"] == user["id"]),
            "isLocked": index in LOCKED and user not in ACCOUNTS.values(),
            "url": ("https://%s/@%s" % (user["host"], user["username"])) if user["host"] else None,
            "pinnedNoteIds": [], "pinnedNotes": [],
        })
        if user["id"] != me["id"]:
            detail.update(self.relation(me, user))
        return detail

    def user_notes(self, user, body, featured=False):
        with lock:
            notes = [n for n in self.by_id.values() if n["userId"] == user["id"]]
        if featured:
            notes = [n for n in notes if n.get("reactions")]
        else:
            if not body.get("withReplies"):
                notes = [n for n in notes if not n.get("replyId")]
            if not body.get("withRenotes"):
                notes = [n for n in notes if not (n.get("renoteId") and n.get("text") is None)]
            if body.get("withFiles"):
                notes = [n for n in notes if n.get("files")]
        notes.sort(key=lambda n: n["id"], reverse=True)
        until = body.get("untilId")
        if until:
            notes = [n for n in notes if n["id"] < until]
        return notes[:min(100, int(body.get("limit") or 10))]

    def user_endpoint(self, endpoint, body, me):
        user = self.find_user(body)
        if user is None:
            return self.api_error(400, "NO_SUCH_USER", "No such user.")
        if endpoint == "users/show":
            return self.send(200, self.detailed(me, user))
        if endpoint == "users/notes":
            return self.send(200, self.user_notes(user, body))
        if endpoint == "users/reactions":
            with lock:
                notes = sorted((n for n in self.by_id.values() if n.get("myReaction")), key=lambda n: n["id"],
                               reverse=True)
            reactions = [{"id": "r" + n["id"], "createdAt": n["createdAt"], "type": n["myReaction"], "note": n}
                         for n in notes] if user["id"] == me["id"] else []
            until = body.get("untilId")
            if until:
                reactions = [r for r in reactions if r["id"] < until]
            return self.send(200, reactions[:min(100, int(body.get("limit") or 10))])
        if endpoint == "users/featured-notes":
            return self.send(200, self.user_notes(user, body, featured=True))
        if user["id"] == me["id"]:
            return self.api_error(400, "IS_YOURSELF", "That is you.")
        relation = self.relation(me, user)
        index = int(user["id"][1:]) if user["id"][1:].isdigit() else -1
        with lock:
            if endpoint == "following/create":
                if relation["isBlocking"]:
                    return self.api_error(400, "BLOCKING", "You are blocking that user.")
                if index in LOCKED:
                    relation["hasPendingFollowRequestFromYou"] = True
                else:
                    relation["isFollowing"] = True
            elif endpoint == "following/delete":
                relation["isFollowing"] = False
            elif endpoint == "following/requests/cancel":
                relation["hasPendingFollowRequestFromYou"] = False
            elif endpoint == "following/update":
                relation["withReplies"] = bool(body.get("withReplies", relation["withReplies"]))
            elif endpoint in ("mute/create", "mute/delete"):
                relation["isMuted"] = endpoint == "mute/create"
            elif endpoint in ("renote-mute/create", "renote-mute/delete"):
                relation["isRenoteMuted"] = endpoint == "renote-mute/create"
            elif endpoint == "blocking/create":
                relation.update(isBlocking=True, isFollowing=False, isFollowed=False,
                                hasPendingFollowRequestFromYou=False)
            elif endpoint == "blocking/delete":
                relation["isBlocking"] = False
            else:
                return self.api_error(400, "NO_SUCH_ENDPOINT", "not mocked: %s" % endpoint)
        return self.send(200, {})

    def search(self, endpoint, body, me):
        limit = min(100, int(body.get("limit") or 10))
        if endpoint == "hashtags/trend":
            return self.send(200, [{"tag": tag, "chart": [users - i % 3 for i in range(20)], "usersCount": users}
                                   for tag, users in (("hibari", 12), ("ねこ", 5), ("今日の一枚", 3))])
        if endpoint == "users/search":
            query = str(body.get("query", "")).lstrip("@").lower()
            everyone = self.users + list(ACCOUNTS.values())
            found = [self.detailed(me, u) for u in everyone
                     if query in u["username"].lower() or query in (u.get("name") or "").lower()]
            offset = int(body.get("offset") or 0)
            return self.send(200, found[offset:offset + limit])
        if endpoint == "notes/search-by-tag":
            needle = "#%s" % body.get("tag", "")
        else:
            needle = str(body.get("query", ""))
        with lock:
            notes = sorted((n for n in self.by_id.values() if needle.lower() in (n.get("text") or "").lower()
                            and (not body.get("userId") or n["userId"] == body["userId"])),
                           key=lambda n: n["id"], reverse=True)
        until = body.get("untilId")
        if until:
            notes = [n for n in notes if n["id"] < until]
        return self.send(200, notes[:limit])

    def favorite_endpoint(self, endpoint, body, me):
        """The account's お気に入り (the app's bookmarks)."""
        with lock:
            favorites = state["favorites"].setdefault(me["id"], [])
            if endpoint == "i/favorites":
                until = body.get("untilId")
                listed = [(f, n) for f, n in favorites if (not until or f < until) and n in self.by_id]
                page = [{"id": f, "createdAt": self.by_id[n]["createdAt"], "noteId": n, "note": self.by_id[n]}
                        for f, n in listed[:min(100, int(body.get("limit") or 10))]]
                return self.send(200, page)
            note_id = body.get("noteId")
            if note_id not in self.by_id:
                return self.api_error(400, "NO_SUCH_NOTE", "No such note.")
            favorited = any(n == note_id for _, n in favorites)
            if endpoint == "notes/state":
                return self.send(200, {"isFavorited": favorited, "isMutedThread": False})
            if endpoint == "notes/favorites/create":
                if favorited:
                    return self.api_error(400, "ALREADY_FAVORITED", "The note has already been marked as a favorite.")
                state["favorited"] += 1
                favorites.insert(0, ("f%06d" % state["favorited"], note_id))
            else:
                if not favorited:
                    return self.api_error(400, "NOT_FAVORITED", "You have not marked that note a favorite.")
                favorites[:] = [(f, n) for f, n in favorites if n != note_id]
        return self.send(204, b"")

    def note_endpoint(self, endpoint, body):
        with lock:
            note = self.by_id.get(body.get("noteId"))
        if note is None:
            return self.api_error(400, "NO_SUCH_NOTE", "No such note.")
        if endpoint == "notes/show":
            return self.send(200, note)
        if endpoint == "notes/conversation":
            chain = []
            parent = note.get("reply")
            while parent is not None and len(chain) < min(100, int(body.get("limit") or 10)):
                chain.append(parent)
                parent = parent.get("reply")
            return self.send(200, chain)
        if endpoint == "notes/replies":
            with lock:
                replies = sorted((n for n in self.by_id.values() if n.get("replyId") == note["id"]), key=lambda n: n["id"])
            since, until = body.get("sinceId"), body.get("untilId")
            if since:
                replies = [n for n in replies if n["id"] > since]
            if until:
                replies = [n for n in replies if n["id"] < until][::-1]
            return self.send(200, replies[:min(100, int(body.get("limit") or 10))])
        if endpoint == "notes/reactions/create":
            key = stored_reaction(str(body.get("reaction", "")))
            if key is None:
                return self.api_error(400, "INVALID_PARAM", "Invalid reaction.")
            with lock:
                if note.get("myReaction"):
                    return self.api_error(400, "ALREADY_REACTED", "You are already reacting to that note.")
                note["reactions"][key] = note["reactions"].get(key, 0) + 1
                note["myReaction"] = key
            return self.send(204, b"")
        if endpoint == "notes/reactions/delete":
            with lock:
                key = note.get("myReaction")
                if not key:
                    return self.api_error(400, "NOT_REACTED", "You are not reacting to that note.")
                count = note["reactions"].get(key, 1) - 1
                if count > 0:
                    note["reactions"][key] = count
                else:
                    note["reactions"].pop(key, None)
                note["myReaction"] = None
            return self.send(204, b"")
        self.api_error(400, "NO_SUCH_ENDPOINT", "not mocked: %s" % endpoint)


def parse_multipart(raw, content_type):
    """Fields (name -> text) and files (name -> (filename, content type, bytes)) of a
    multipart/form-data body."""
    boundary = content_type.split("boundary=", 1)[-1].strip().strip('"').encode()
    fields, files = {}, {}
    for part in raw.split(b"--" + boundary):
        if part in (b"", b"--", b"--\r\n", b"\r\n") or b"\r\n\r\n" not in part:
            continue
        head, _, data = part.partition(b"\r\n\r\n")
        data = data[:-2] if data.endswith(b"\r\n") else data
        headers = {}
        for line in head.decode("utf-8", "replace").split("\r\n"):
            if ":" in line:
                key, value = line.split(":", 1)
                headers[key.strip().lower()] = value.strip()
        disposition = dict(
            item.strip().split("=", 1) for item in headers.get("content-disposition", "").split(";") if "=" in item)
        name = disposition.get("name", "").strip('"')
        if "filename" in disposition:
            files[name] = (disposition["filename"].strip('"'), headers.get("content-type", "application/octet-stream"),
                           data)
        else:
            fields[name] = data.decode("utf-8", "replace")
    return fields, files


def image_size(data):
    """Width and height of a PNG, GIF or JPEG, or (None, None)."""
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", data[16:24])
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return struct.unpack("<HH", data[6:10])
    if data[:2] == b"\xff\xd8":
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            length = struct.unpack(">H", data[i + 2:i + 4])[0]
            if marker in (0xC0, 0xC1, 0xC2):
                height, width = struct.unpack(">HH", data[i + 5:i + 9])
                return width, height
            i += 2 + length
    return None, None


def stored_reaction(reaction):
    """The key Misskey stores a reaction under, or None if this server cannot take it."""
    if len(reaction) > 2 and reaction.startswith(":") and reaction.endswith(":"):
        name = reaction[1:-1]
        return ":%s@.:" % name if name in {e[0] for e in EMOJIS} else None
    if not reaction:
        return None
    return reaction if "\u200d" in reaction else reaction.replace("\ufe0f", "")


def timelines(notes):
    """Home: people the account follows; featured (ハイライト): local notes with reactions;
    local: local users; social: both; global: all."""
    followed = {"u%02d" % i for i in FOLLOWED}
    home = [n for n in notes if n["userId"] in followed]
    local = [n for n in notes if n["user"]["host"] is None]
    social = [n for n in notes if n["userId"] in followed or n["user"]["host"] is None]
    featured = [n for n in local if n.get("reactions")]
    return dict(zip(TIMELINES, (home, featured, local, social, list(notes))))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=0, help="listen port (0 asks the OS for a free port)")
    parser.add_argument("--latency", type=float, default=0.0, help="seconds added to every API call")
    parser.add_argument("--ready-file", type=Path, help="write the URL once the server is ready")
    args = parser.parse_args()
    try:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError as error:
        print("mock Misskey not started on port %d: %s" % (args.port, error), file=sys.stderr)
        return 1
    base = "http://localhost:%d" % server.server_port
    users, emojis, notes, replies = build(base)
    Handler.base, Handler.users, Handler.emojis = base, users, emojis
    for user in ACCOUNTS.values():
        user["avatarUrl"] = "%s/media/avatar/%s.png?w=400&h=400" % (base, user["id"])
    Handler.timelines = timelines(notes)
    Handler.by_id = {n["id"]: n for n in notes + replies}
    for note in Handler.by_id.values():
        note["repliesCount"] = 0
    for note in Handler.by_id.values():
        if note.get("replyId") in Handler.by_id:
            Handler.by_id[note["replyId"]]["repliesCount"] += 1
    now = datetime.datetime.now(datetime.timezone.utc)
    for user, unread in ((ME, 3), (SUB, 2)):
        state["notifications"][user["id"]] = build_notifications(base, user, users, notes, Handler.by_id, now)
        state["unread"][user["id"]] = unread
    Handler.latency = args.latency

    if args.ready_file:
        args.ready_file.write_text(base)
    print("mock Misskey at %s" % base, file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
