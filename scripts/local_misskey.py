#!/usr/bin/env python3
"""A real Misskey (the official Docker image) on http://localhost:3000 for development.

It is cut off from the fediverse: Misskey has no route out of its Docker network (no
federation or remote media; URL previews work only for the test pages served inside it,
scripts/local_misskey/sites), the port listens on 127.0.0.1 only, and the server's
federation setting is "none". See scripts/local_misskey/compose.yml.

    scripts/local_misskey.py up         # starts it; the first time also sets it up and seeds it
    scripts/local_misskey.py down       # stops it (the data stays)
    scripts/local_misskey.py reset      # deletes all the data, then `up`
    scripts/local_misskey.py approve    # approves the sign-in open in the app in the Simulator
    scripts/local_misskey.py post       # new notes from followed accounts, for pull-to-refresh
    scripts/local_misskey.py notify     # notifications for @hibari (reactions, renotes, a reply, ...)

Accounts (the password of each is "hibari"): @hibari (the one to use in the app; follows
@alice @bob @carol @hibari_sub), @hibari_sub (follows only @bob), @alice, @bob, @carol,
@dave (followed by nobody: not in @hibari's home timeline), @newsbot (a bot) and @admin
(the administrator, for the web UI's control panel).

The seed has about 100 notes: MFM, custom emojis (static, wide and animated), images, a
GIF, a video, sensitive media, CW, a poll, renotes, quotes, a reply thread, mentions,
hashtags, a long note, non-public visibilities, reactions and links to the test pages (URL
previews of each kind). Every note is dated when the seed ran: Misskey takes no dates from
the API.

Sign in from the app with the server `http://localhost:3000`. On the Misskey page the app
opens, sign in with the account's password and allow, or instead run `approve` (as @hibari;
`approve --as hibari_sub` for another account): it approves the session the page is for
and sends the app in the booted Simulator the callback, which closes the page.
"""

import argparse
import datetime
import json
import math
import os
import plistlib
import random
import re
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zlib

URL = "http://localhost:3000"
COMPOSE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "local_misskey", "compose.yml")
PASSWORD = "hibari"


def compose(*args, capture=False, stdin=None):
    command = ["docker", "compose", "-f", COMPOSE, *args]
    if capture:
        return subprocess.run(command, check=True, stdout=subprocess.PIPE, input=stdin).stdout
    subprocess.run(command, check=True)


class APIError(Exception):
    pass


def api(endpoint, token=None, **params):
    if token:
        params["i"] = token
    request = urllib.request.Request("%s/api/%s" % (URL, endpoint), data=json.dumps(params).encode(),
                                     headers={"Content-Type": "application/json"})
    return send(endpoint, request)


def upload(token, name, data, mime, sensitive=False, comment=None):
    """A drive file (`drive/files/create`, multipart)."""
    boundary = uuid.uuid4().hex
    fields = {"i": token, "name": name, "force": "true", "isSensitive": "true" if sensitive else "false"}
    if comment:
        fields["comment"] = comment
    body = bytearray()
    for key, value in fields.items():
        body += ('--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n' % (boundary, key, value)).encode()
    body += ('--%s\r\nContent-Disposition: form-data; name="file"; filename="%s"\r\nContent-Type: %s\r\n\r\n'
             % (boundary, name, mime)).encode()
    body += data + ("\r\n--%s--\r\n" % boundary).encode()
    request = urllib.request.Request("%s/api/drive/files/create" % URL, data=bytes(body),
                                     headers={"Content-Type": "multipart/form-data; boundary=%s" % boundary})
    return send("drive/files/create", request)


def send(endpoint, request):
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            data = response.read()
    except urllib.error.HTTPError as error:
        raise APIError("%s: HTTP %d %s" % (endpoint, error.code, error.read().decode(errors="replace")))
    return json.loads(data) if data else None


def wait_until_up(timeout=300):
    deadline = time.time() + timeout
    while True:
        try:
            return api("meta")
        except (OSError, APIError):
            if time.time() > deadline:
                sys.exit("Misskey did not come up at %s (docker compose -f %s logs web)" % (URL, COMPOSE))
            time.sleep(2)


def sql(query):
    """One value from the database (queries are made from constants and checked input)."""
    output = compose("exec", "-T", "db", "psql", "-U", "misskey", "-d", "misskey", "-tAc", query, capture=True)
    return output.decode().strip()


def native_token(username):
    """An account's own (web client) token, which `secure` endpoints like miauth/gen-token
    need. Accounts are looked up in the database, so this works for any local account."""
    if not re.fullmatch(r"[A-Za-z0-9_]+", username):
        sys.exit("not a username: %s" % username)
    token = sql("SELECT token FROM \"user\" WHERE \"usernameLower\" = '%s' AND host IS NULL" % username.lower())
    if not token:
        sys.exit("no local account @%s" % username)
    return token


def ffmpeg(*args, suffix):
    script = 'f=$(mktemp --suffix=%s) && ffmpeg -hide_banner -loglevel error -y "$@" "$f" && cat "$f"; rm -f "$f"' % suffix
    return compose("exec", "-T", "web", "sh", "-c", script, "ffmpeg", *args, capture=True)


def hex_color(rng):
    return "%02x%02x%02x" % tuple(rng.randint(30, 240) for _ in range(3))


def picture(rng, width, height):
    """A JPEG: a fractal or a gradient in random colors."""
    kind = rng.choice(["mandelbrot", "mandelbrot", "gradients", "sierpinski"])
    if kind == "mandelbrot":
        x, y = rng.choice([(-0.743643887, 0.131825904), (-0.7453, 0.1127), (-1.25066, 0.02012), (-0.16, 1.0405),
                           (0.2549870375, 0.0005679), (-1.7497, 0.0)])
        source = "mandelbrot=s=%dx%d:maxiter=400:start_x=%f:start_y=%f:start_scale=%f:inner=period" % (
            width, height, x, y, rng.choice([0.002, 0.01, 0.05]))
    elif kind == "gradients":
        source = "gradients=s=%dx%d:c0=0x%s:c1=0x%s:c2=0x%s:nb_colors=3:seed=%d:type=%s" % (
            width, height, hex_color(rng), hex_color(rng), hex_color(rng), rng.randint(0, 9999),
            rng.choice(["linear", "radial", "circular", "spiral"]))
    else:
        source = "sierpinski=s=%dx%d:seed=%d:type=%s" % (width, height, rng.randint(0, 9999), rng.choice(["carpet", "triangle"]))
    return ffmpeg("-f", "lavfi", "-i", source, "-frames:v", "1", "-q:v", "3", suffix=".jpg")


def animated_gif(rng):
    source = "life=s=160x160:mold=10:ratio=0.3:seed=%d:rate=10:life_color=#%s:death_color=#1e293b:mold_color=#%s,scale=320:320:flags=neighbor" % (
        rng.randint(0, 9999), hex_color(rng), hex_color(rng))
    return ffmpeg("-f", "lavfi", "-i", source, "-t", "2", suffix=".gif")


def video():
    return ffmpeg("-f", "lavfi", "-i", "testsrc2=s=640x360:r=30:d=6", "-f", "lavfi", "-i", "sine=frequency=440:duration=6",
                  "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", "-movflags", "+faststart", suffix=".mp4")


def png_chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def rgba_rows(width, height, shade, samples=3):
    """Raw PNG rows (filter 0) of `shade(u, v) -> (r, g, b, a)`, u and v in -1...1 across
    the height (v up), antialiased by supersampling."""
    scale = 2 / height
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            r = g = b = a = 0
            for sy in range(samples):
                for sx in range(samples):
                    u = (x + (sx + 0.5) / samples - width / 2) * scale
                    v = (height / 2 - y - (sy + 0.5) / samples) * scale
                    pr, pg, pb, pa = shade(u, v)
                    r, g, b, a = r + pr * pa, g + pg * pa, b + pb * pa, a + pa
            if a:
                rows += bytes((int(r / a), int(g / a), int(b / a), int(255 * a / samples ** 2)))
            else:
                rows += b"\x00\x00\x00\x00"
    return bytes(rows)


def png(width, height, shade):
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header)
            + png_chunk(b"IDAT", zlib.compress(rgba_rows(width, height, shade), 9)) + png_chunk(b"IEND", b""))


def apng(width, height, shades, delay_ms):
    """An animated PNG, one frame per shade function, looping."""
    out = b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    out += png_chunk(b"acTL", struct.pack(">II", len(shades), 0))
    sequence = 0
    for index, shade in enumerate(shades):
        out += png_chunk(b"fcTL", struct.pack(">IIIIIHHBB", sequence, width, height, 0, 0, delay_ms, 1000, 0, 0))
        sequence += 1
        data = zlib.compress(rgba_rows(width, height, shade), 9)
        if index == 0:
            out += png_chunk(b"IDAT", data)
        else:
            out += png_chunk(b"fdAT", struct.pack(">I", sequence) + data)
            sequence += 1
    return out + png_chunk(b"IEND", b"")


CLEAR = (0, 0, 0, 0)


def segment_distance(u, v, a, b):
    (ax, ay), (bx, by) = a, b
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((u - ax) * dx + (v - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(u - ax - t * dx, v - ay - t * dy)


def in_polygon(u, v, points):
    inside = False
    for (ax, ay), (bx, by) in zip(points, points[1:] + points[:1]):
        if (ay > v) != (by > v) and u < ax + (v - ay) * (bx - ax) / (by - ay):
            inside = not inside
    return inside


def emoji_smile(u, v):
    if math.hypot(u, v) > 0.92:
        return CLEAR
    if math.hypot(u + 0.32, v - 0.25) < 0.12 or math.hypot(u - 0.32, v - 0.25) < 0.12:
        return (60, 40, 20, 1)
    if 0.42 < math.hypot(u, v + 0.05) < 0.56 and v < -0.12:
        return (60, 40, 20, 1)
    return (255, 204, 51, 1)


def emoji_heart(u, v):
    x, y = u * 1.3, v * 1.3 + 0.15
    return (244, 114, 182, 1) if (x * x + y * y - 1) ** 3 - x * x * y ** 3 <= 0 else CLEAR


STAR = [(0.95 * math.cos(math.pi / 2 + i * math.pi / 5) * (1 if i % 2 == 0 else 0.45),
         0.95 * math.sin(math.pi / 2 + i * math.pi / 5) * (1 if i % 2 == 0 else 0.45) - 0.06) for i in range(10)]


def emoji_star(u, v):
    return (250, 190, 30, 1) if in_polygon(u, v, STAR) else CLEAR


def emoji_check(u, v):
    if math.hypot(u, v) > 0.92:
        return CLEAR
    if min(segment_distance(u, v, (-0.45, 0.02), (-0.12, -0.32)), segment_distance(u, v, (-0.12, -0.32), (0.48, 0.36))) < 0.12:
        return (255, 255, 255, 1)
    return (34, 197, 94, 1)


def emoji_hibari(u, v):
    if max(abs(u), abs(v)) > 0.92 or math.hypot(max(abs(u) - 0.62, 0), max(abs(v) - 0.62, 0)) > 0.3:
        return CLEAR
    if (abs(u) < 0.5 and abs(v) < 0.55) and (abs(u) > 0.3 or abs(v) < 0.1):
        return (255, 255, 255, 1)
    return (29, 155, 240, 1)


def emoji_wide(u, v):
    if math.hypot(max(abs(u) - 2.1, 0), v) > 0.85:
        return CLEAR
    if any(math.hypot(u - x, v) < 0.3 for x in (-1.2, 0, 1.2)):
        return (255, 255, 255, 1)
    t = (u + 3) / 6
    return (int(99 + (236 - 99) * t), int(102 + (72 - 102) * t), int(241 + (153 - 241) * t), 1)


def emoji_spin(frame, frames):
    def shade(u, v):
        r = math.hypot(u, v)
        if not 0.5 < r < 0.9:
            return CLEAR
        angle = (math.atan2(v, u) / (2 * math.pi) - frame / frames) % 1
        return (int(255 * angle), int(120 + 100 * (1 - angle)), 255, 0.25 + 0.75 * angle)
    return shade


def site_images(rng):
    """The images of the test pages (scripts/local_misskey/sites), into the `sites` service."""
    images = {
        "desk-rack.jpg": picture(rng, 1200, 630),
        "long-title.jpg": picture(rng, 1200, 630),
        "hello.jpg": picture(rng, 400, 400),
        "keyboard.jpg": picture(rng, 1600, 900),
        "video.jpg": picture(rng, 1280, 720),
        "adult.jpg": picture(rng, 1200, 630),
        "logo.png": png(256, 256, emoji_hibari),
    }
    for name, data in images.items():
        compose("exec", "-T", "sites", "sh", "-c", 'cat > "/srv/img/$1"', "sh", name, capture=True, stdin=data)


def custom_emojis():
    """(name, category, aliases, PNG data)"""
    return [
        ("hibari", "hibari", ["ひばり"], png(128, 128, emoji_hibari)),
        ("blob_smile", "face", ["smile", "にこにこ"], png(128, 128, emoji_smile)),
        ("heart_pink", "symbol", ["heart", "ハート"], png(128, 128, emoji_heart)),
        ("star_gold", "symbol", ["star", "ほし"], png(128, 128, emoji_star)),
        ("check_green", "symbol", ["ok", "よし"], png(128, 128, emoji_check)),
        ("wide_dots", "hibari", ["typing", "入力中"], png(384, 128, emoji_wide)),
        ("spin_ring", "hibari", ["loading", "くるくる"], apng(128, 128, [emoji_spin(i, 12) for i in range(12)], 80)),
    ]


ACCOUNTS = [
    ("hibari", "ひばり :hibari:", "Hibari の開発用アカウント。**メイン**で使う", {}),
    ("hibari_sub", "サブ垢", "アカウント切り替えのテスト用", {}),
    ("alice", "Alice", "写真と投票が好き :heart_pink:", {}),
    ("bob", "ボブ", "にゃーん", {"isCat": True}),
    ("carol", "Carol :star_gold:", "MFM で遊ぶ人\n$[x2 🎨]", {}),
    ("dave", "dave", "誰にもフォローされていない（ホームTLには出ない）", {}),
    ("newsbot", "お知らせbot", "定期的に何かを言う bot", {"isBot": True}),
]
FOLLOWS = {"hibari": ["alice", "bob", "carol", "hibari_sub"], "hibari_sub": ["bob"],
           "alice": ["hibari", "bob", "carol"], "bob": ["hibari", "alice"], "carol": ["hibari", "alice", "bob"]}

PHRASES = [
    "今日はいい天気", "コーヒーがおいしい", "電車が遅れてる", "新しいキーボードを買った", "眠い",
    "お昼なに食べよう", "やっと金曜日", "雨の音が好き", "散歩してきた", "積読が増える一方",
    "猫がキーボードの上で寝てる", "締め切りが近い", "ラーメン食べたい", "夕焼けがきれいだった", "部屋の掃除をした",
    "Swift のビルドが速くなった気がする", "スクロールがぬるぬる", "120Hz は正義", "ハプティクスが気持ちいい",
    "タイムラインを眺めてる", "今日も一日おつかれさま", "お茶をいれた", "朝ごはんはパン派", "週末はどこに行こうかな",
    "イヤホンの片方がない", "明日は早起きする（たぶん）", "カレーを作りすぎた", "新しいアイコンにした", "ねこ",
]
REACTIONS = ["👍", "❤️", "🎉", "😂", "🤔", "👀", "🙏", ":heart_pink:", ":blob_smile:", ":star_gold:", ":check_green:",
             ":hibari:", ":spin_ring:", ":wide_dots:"]
FOLLOWED = ["alice", "bob", "carol", "hibari_sub"]


def seed():
    rng = random.Random(1)
    print("Setting up: accounts, custom emojis, notes (about half a minute)...", flush=True)
    admin = api("admin/accounts/create", username="admin", password=PASSWORD)["token"]
    api("admin/update-meta", admin, name="Hibari Dev", description="Hibari の開発用ローカルサーバー（どこにも連合しない）",
        federation="none", disableRegistration=True, urlPreviewEnabled=True)
    api("admin/roles/update-default-policies", admin, policies={"canSearchNotes": True})
    api("i/update", admin, name="管理者")

    for name, category, aliases, data in custom_emojis():
        file = upload(admin, name + ".png", data, "image/png")
        api("admin/emoji/add", admin, name=name, fileId=file["id"], category=category, aliases=aliases)

    tokens, ids = {}, {}
    for username, name, description, extra in ACCOUNTS:
        created = api("admin/accounts/create", admin, username=username, password=PASSWORD)
        tokens[username], ids[username] = created["token"], created["id"]
        avatar = upload(created["token"], "avatar.jpg", picture(rng, 400, 400), "image/jpeg")
        banner = upload(created["token"], "banner.jpg", picture(rng, 1500, 500), "image/jpeg")
        api("i/update", created["token"], name=name, description=description, avatarId=avatar["id"],
            bannerId=banner["id"], **extra)
    for username, followees in FOLLOWS.items():
        for followee in followees:
            api("following/create", tokens[username], userId=ids[followee])

    def note(username, text=None, images=(), **params):
        file_ids = []
        for spec in images:
            if isinstance(spec, dict):
                file_ids.append(upload(tokens[username], **spec)["id"])
            else:
                width, height = spec
                file_ids.append(upload(tokens[username], "image.jpg", picture(rng, width, height), "image/jpeg")["id"])
        if file_ids:
            params["fileIds"] = file_ids
        if text is not None:
            params["text"] = text
        return api("notes/create", tokens[username], **params)["createdNote"]

    def react(note_id, users, reactions=None):
        for index, username in enumerate(users):
            reaction = reactions[index % len(reactions)] if reactions else rng.choice(REACTIONS)
            api("notes/reactions/create", tokens[username], noteId=note_id, reaction=reaction)

    everyone = [account[0] for account in ACCOUNTS]
    sizes = [(1200, 800), (800, 1200), (1000, 1000), (1600, 900), (900, 1600), (2000, 600)]

    for index in range(75):
        username = rng.choice(["alice", "bob", "carol", "dave", "newsbot", "hibari_sub", "alice", "bob"])
        text = "。".join(rng.sample(PHRASES, rng.randint(1, 3)))
        if rng.random() < 0.3:
            text += " " + rng.choice(["🍵", "☕", "🐈", "🌧️", "✨", ":blob_smile:", ":heart_pink:", ":star_gold:", ":hibari:"])
        if rng.random() < 0.15:
            text += " #" + rng.choice(["今日の一枚", "hibari_dev", "ねこ", "ごはん"])
        images = [rng.choice(sizes) for _ in range(rng.choice([1, 1, 2, 4]))] if rng.random() < 0.18 else []
        cw = "ちょっとした愚痴" if rng.random() < 0.05 else None
        created = note(username, text, images, **({"cw": cw} if cw else {}))
        if rng.random() < 0.4:
            react(created["id"], rng.sample([u for u in everyone if u != username], rng.randint(1, 4)))

    note("dave", "この投稿は @hibari のホームタイムラインには出ないはず（誰も dave をフォローしていない）")
    note("newsbot", "【お知らせ】このサーバーは開発用で、どこにも連合しません\nMisskey のドキュメント: https://misskey-hub.net/ja/docs/")
    long = note("alice", "長い投稿のテスト。" + "\n".join(
        "%d. %s。%s。" % (i + 1, PHRASES[i], PHRASES[(i * 7) % len(PHRASES)]) for i in range(24)))
    note("bob", "コードのテスト `let x = 1` はインライン\n```swift\nfunc greet(_ name: String) -> String {\n    \"Hello, \\(name)!\"\n}\n```")
    note("carol", "MFM いろいろ\n$[x2 大きい] **太字** <small>小さい</small> <i>斜体</i> ~~打ち消し~~\n"
         "$[spin くるくる] $[jelly ぷるぷる] $[tada じゃーん] $[flip 反転]\n"
         "$[fg.color=e11d48 赤い字] $[bg.color=fde047 黄色い背景] $[ruby 雲雀 ひばり]\n<center>中央寄せ</center>\n> 引用のブロック")
    poll = note("alice", "今日のお昼は？", poll={"choices": ["ラーメン", "カレー", "そば", "パン"], "multiple": False,
                                           "expiredAfter": 7 * 24 * 3600 * 1000})
    for username, choice in (("bob", 0), ("carol", 1), ("dave", 0), ("hibari_sub", 3)):
        api("notes/polls/vote", tokens[username], noteId=poll["id"], choice=choice)
    note("bob", "犯人はヤス", cw="ネタバレ注意（CW のテスト）")
    note("alice", "センシティブ設定の画像", [{"name": "sensitive.jpg", "data": picture(rng, 1200, 800), "mime": "image/jpeg",
                                          "sensitive": True}])
    note("carol", "4枚", [(1200, 800), (800, 1200), (1000, 1000), (1600, 900)])
    gallery = note("alice", "2枚。代替テキストつき", [
        {"name": "a.jpg", "data": picture(rng, 1200, 800), "mime": "image/jpeg", "comment": "フラクタルの画像（代替テキスト）"},
        {"name": "b.jpg", "data": picture(rng, 1200, 800), "mime": "image/jpeg"}])
    note("bob", "縦長", [(900, 1600)])
    note("carol", "3枚", [(1000, 1000), (1200, 800), (800, 1200)])
    note("alice", "パノラマ", [(2400, 600)])
    note("bob", "GIF アニメ", [{"name": "life.gif", "data": animated_gif(rng), "mime": "image/gif"}])
    note("carol", "動画（6秒、音つき）", [{"name": "testsrc.mp4", "data": video(), "mime": "video/mp4"}])
    note("alice", "@hibari 見てる？ #hibari_dev")
    api("notes/create", tokens["bob"], renoteId=gallery["id"])
    note("carol", "投票した", renoteId=poll["id"])
    thread = note("alice", "スレッドのテスト。返信してね")
    reply = note("bob", "返信 1", replyId=thread["id"])
    reply = note("alice", "返信 1 への返信", replyId=reply["id"])
    note("carol", "さらに返信", replyId=reply["id"])
    note("hibari", "スレッドに返信", replyId=thread["id"])
    note("dave", "フォローされていない人からの返信", replyId=thread["id"])
    note("hibari", "テストサーバーにようこそ :blob_smile:")
    emojis = note("alice", "カスタム絵文字 :hibari: :blob_smile: :heart_pink: :star_gold: :check_green:\n"
                           "横長 :wide_dots: アニメ :spin_ring: $[x2 :hibari:]")
    note("bob", "フォロワー限定の投稿", visibility="followers")
    note("carol", "ホーム限定の投稿", visibility="home")
    note("alice", "@hibari ダイレクトのテスト", visibility="specified", visibleUserIds=[ids["hibari"]])
    note("hibari_sub", "サブアカウントから")

    # URL previews of the test pages: cards (which take the link's place at the start or the
    # end of the text), and where none shows.
    site_images(rng)
    note("alice", "19インチマウント搭載卓上ラック\n品番：MR-LCAV2U25（奥行250mm・2U）/ MR-LCAV4U40（奥行400mm・4U）\n\n"
                  "▽ニュースリリースはこちら\nhttp://news.hibari.test/articles/desk-rack")
    note("bob", "ブログはじめたらしい（twitter:card が summary：小さいカード） http://blog.hibari.test/posts/hello")
    note("carol", "キーボード買った（twitter:card なし、横長の画像：大きいカード） http://www.hibari-shop.test/items/42")
    note("alice", "http://news.hibari.test/articles/long-title\nタイトルの長い記事（先頭のリンクも本文から消える）")
    note("bob", "動画のページ http://video.hibari.test/watch/1")
    note("carol", "途中のリンク http://www.hibari-shop.test/items/42 は本文に残る")
    note("alice", "画像のないページ（小さいカード） http://docs.hibari.test/guide")
    note("alice", "リンク切れ（カードなし、長いURLは省略） http://news.hibari.test/articles/missing")
    note("bob", "センシティブなページ（画像は出ない） http://adult.hibari.test/")
    note("carol", "ロゴだけのページ（twitter:card なし、正方形：小さいカード） http://club.hibari.test/")
    note("alice", "リンクと画像（カードは出ない） http://news.hibari.test/articles/desk-rack", [(1200, 800)])
    note("bob", "リンクつきの引用（カードは出ない） http://blog.hibari.test/posts/hello", renoteId=thread["id"])
    note("carol", "リンクと投票（カードは出ない） http://docs.hibari.test/guide",
         poll={"choices": ["はい", "いいえ"], "multiple": False, "expiredAfter": 7 * 24 * 3600 * 1000})
    note("alice", "リンク2つ http://docs.hibari.test/guide と http://blog.hibari.test/posts/hello（カードは後のほう）")
    note("bob", "?[プレビューしないリンク](http://news.hibari.test/articles/desk-rack) だけ（カードなし）")
    note("carol", "CW の中のリンク http://www.hibari-shop.test/items/42", cw="買い物の話")

    newest = note("alice", "いちばん新しい投稿", [(1200, 800)])

    react(emojis["id"], ["bob", "carol", "dave", "hibari_sub", "newsbot", "hibari"],
          [":heart_pink:", ":blob_smile:", ":wide_dots:", ":spin_ring:", "🎉", ":star_gold:"])
    react(long["id"], ["bob", "carol", "hibari"], ["👀", "👀", "🙏"])
    react(gallery["id"], ["bob", "carol", "dave", "hibari_sub"], ["❤️", "❤️", ":heart_pink:", "🎉"])
    react(thread["id"], ["bob", "carol"], ["👍"])
    react(newest["id"], ["bob", "carol", "hibari"], ["👍", ":check_green:", "❤️"])


def summary():
    meta = api("meta")
    print("Misskey %s at %s (federation: %s)" % (meta["version"], URL, meta.get("federation")))
    print("Accounts (password: %s): @hibari (for the app), @hibari_sub, @alice, @bob, @carol, @dave, @newsbot, @admin"
          % PASSWORD)


def up(args):
    compose("up", "-d", "--wait", "--wait-timeout", "300")
    meta = wait_until_up()
    if meta.get("requireSetup"):
        seed()
    summary()


def down(args):
    compose("down")


def reset(args):
    compose("down", "--volumes")
    up(args)


def approve(args):
    """Does what the MiAuth page's "allow" does: makes the token for the session (as the
    given account) and sends the app the callback."""
    if args.url:
        target = args.url if "/" in args.url else "/miauth/" + args.url
    else:
        log = compose("logs", "--no-log-prefix", "proxy", capture=True).decode(errors="replace")
        pages = re.findall(r'"GET (/miauth/[^ "]+) HTTP', log)
        if not pages:
            sys.exit("No MiAuth sign-in yet: start one from the app (server %s) first" % URL)
        target = pages[-1]
    parsed = urllib.parse.urlsplit(target)
    session = parsed.path.rstrip("/").rsplit("/", 1)[-1]
    if not re.fullmatch(r"[A-Za-z0-9-]+", session):
        sys.exit("not a MiAuth session: %s" % session)
    query = dict(urllib.parse.parse_qsl(parsed.query))
    if sql("SELECT count(*) FROM access_token WHERE session = '%s'" % session) != "0":
        print("Session %s was approved already" % session)
    else:
        permission = [p for p in query.get("permission", "").split(",") if p]
        api("miauth/gen-token", native_token(args.username), session=session, name=query.get("name"),
            iconUrl=query.get("icon"), permission=permission)
        print("Approved %s as @%s" % (session, args.username))
    callback = query.get("callback")
    if not callback:
        return
    callback += ("&" if "?" in callback else "?") + "session=" + urllib.parse.quote(session)
    app = simulator_app(urllib.parse.urlsplit(callback).scheme)
    if app and subprocess.run(["xcrun", "simctl", "openurl", "booted", callback], stdout=subprocess.DEVNULL).returncode == 0:
        print("Sent %s the callback in the Simulator" % app)
    else:
        print("Open %s to return to the app" % callback)


def simulator_app(scheme):
    """The bundle ID of the booted Simulator's app for `scheme:` URLs, if any."""
    listing = subprocess.run(["xcrun", "simctl", "listapps", "booted"], capture_output=True)
    if listing.returncode:
        return None
    converted = subprocess.run(["plutil", "-convert", "xml1", "-o", "-", "-"], input=listing.stdout, capture_output=True)
    for bundle_id, app in plistlib.loads(converted.stdout).items():
        try:
            with open(os.path.join(app["Path"], "Info.plist"), "rb") as f:
                info = plistlib.load(f)
        except (KeyError, OSError, plistlib.InvalidFileException):
            continue
        if any(scheme in url_type.get("CFBundleURLSchemes", []) for url_type in info.get("CFBundleURLTypes", [])):
            return bundle_id
    return None


def post(args):
    rng = random.Random()
    for _ in range(args.n):
        username = args.username or rng.choice(FOLLOWED)
        token = native_token(username)
        text = args.text or "%s %s" % (rng.choice(PHRASES), datetime.datetime.now().strftime("%H:%M:%S"))
        params = {"text": text}
        if args.image:
            params["fileIds"] = [upload(token, "image.jpg", picture(rng, *rng.choice([(1200, 800), (800, 1200), (1000, 1000)])),
                                        "image/jpeg")["id"] for _ in range(args.image)]
        api("notes/create", token, **params)
        print("@%s: %s" % (username, text))


def notify(args):
    """A note by the account and what other accounts do with it: reactions and renotes
    (which Misskey groups), a reply, a quote, a mention and a follow."""
    target = args.username
    token = native_token(target)
    user_id = sql("SELECT id FROM \"user\" WHERE \"usernameLower\" = '%s' AND host IS NULL" % target.lower())
    stamp = datetime.datetime.now().strftime("%H:%M:%S")
    note = api("notes/create", token, text="通知のテスト %s :hibari:" % stamp)["createdNote"]
    others = [u for u in ("alice", "bob", "carol", "dave", "newsbot") if u != target]
    for username, reaction in zip(others, ["👍", ":heart_pink:", "🎉", ":blob_smile:", ":wide_dots:"]):
        api("notes/reactions/create", native_token(username), noteId=note["id"], reaction=reaction)
    for username in others[1:3]:
        api("notes/create", native_token(username), renoteId=note["id"])
    api("notes/create", native_token(others[0]), text="返信です %s" % stamp, replyId=note["id"])
    api("notes/create", native_token(others[2]), text="引用します", renoteId=note["id"])
    api("notes/create", native_token(others[1]), text="@%s メンションのテスト %s" % (target, stamp))
    follower = native_token("dave") if target != "dave" else native_token("alice")
    try:
        api("following/delete", follower, userId=user_id)
    except APIError:
        pass
    api("following/create", follower, userId=user_id)
    print("Notified @%s: %d reactions, 2 renotes, a reply, a quote, a mention and a follow" % (target, len(others)))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("up", help="start (and set up and seed the first time)").set_defaults(run=up)
    commands.add_parser("down", help="stop; the data stays").set_defaults(run=down)
    commands.add_parser("reset", help="delete all the data and start over").set_defaults(run=reset)
    command = commands.add_parser("approve", help="approve the latest MiAuth sign-in and return to the app")
    command.add_argument("url", nargs="?", help="the MiAuth page's URL or session (default: the newest one opened)")
    command.add_argument("--as", dest="username", default="hibari", help="the account to sign in as (default: hibari)")
    command.set_defaults(run=approve)
    command = commands.add_parser("post", help="new notes, by default from a random account @hibari follows")
    command.add_argument("-n", type=int, default=1, help="how many (default: 1)")
    command.add_argument("--image", type=int, default=0, help="images per note")
    command.add_argument("--as", dest="username", help="the author")
    command.add_argument("--text", help="the text (default: a random phrase and the time)")
    command.set_defaults(run=post)
    command = commands.add_parser("notify", help="notifications for an account: reactions, renotes, a reply, ...")
    command.add_argument("--as", dest="username", default="hibari", help="the account notified (default: hibari)")
    command.set_defaults(run=notify)
    args = parser.parse_args()
    try:
        args.run(args)
    except APIError as error:
        sys.exit(str(error))
    except subprocess.CalledProcessError as error:
        sys.exit("failed: %s" % " ".join(error.cmd))


if __name__ == "__main__":
    main()
