#!/usr/bin/env python3
"""Uploads a release build to App Store Connect and submits it for review.

    scripts/release.py status                 # the App Store versions and the latest builds
    scripts/release.py release 1.2            # bump, archive, upload, wait, then fill in version 1.2
    scripts/release.py release 1.2 --submit   # ... and submit it for review
    scripts/release.py submit 1.2             # submit a version already filled in

`release` runs these steps, each of which can also be run alone:

    bump 1.2      sets MARKETING_VERSION to 1.2 and CURRENT_PROJECT_VERSION to one past the
                  highest build uploaded so far, and commits that
    upload        archives the Release build of HEAD and uploads it
    prepare 1.2   waits for the uploaded build to finish processing, creates version 1.2 (or
                  renames the version being edited), sets its "What's New" from
                  release-notes/1.2/<locale>.txt and selects the build

The release notes need one file per localization of the app on App Store Connect, e.g.
release-notes/1.2/ja.txt. `prepare` stops before changing anything if one is missing. They
cover what changed since the last release's tag (git log v1.1..).

`submit` tags the commit the submitted build was made from as v1.2 (it doesn't push). `bump` and
`upload` refuse to run with uncommitted changes, other than to release-notes/, so that the build
is that commit.

Archiving and uploading sign in as the Apple ID added in Xcode (Settings → Accounts). Everything
else uses an App Store Connect API key (a team key, App Manager or above):
~/.appstoreconnect/private_keys/AuthKey_<key ID>.p8, plus the issuer ID in ASC_ISSUER_ID or
~/.appstoreconnect/issuer_id. ASC_KEY_ID picks the key when there are several.
"""

import argparse
import base64
import json
import os
import plistlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PBXPROJ = ROOT / "hibari.xcodeproj" / "project.pbxproj"
NOTES_DIR = ROOT / "release-notes"
KEYS_DIR = Path.home() / ".appstoreconnect" / "private_keys"
API = "https://api.appstoreconnect.apple.com"

# appStoreState values of a version that can still be edited (App Store Connect allows one).
EDITABLE_STATES = {
    "PREPARE_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "REJECTED",
    "METADATA_REJECTED",
    "INVALID_BINARY",
}


def fail(message):
    sys.exit(f"release.py: {message}")


# --- API key ---


def api_key():
    key_id = os.environ.get("ASC_KEY_ID")
    if key_id:
        path = KEYS_DIR / f"AuthKey_{key_id}.p8"
    else:
        keys = sorted(KEYS_DIR.glob("AuthKey_*.p8"))
        if len(keys) != 1:
            fail(f"put one AuthKey_<key ID>.p8 in {KEYS_DIR}, or set ASC_KEY_ID")
        path = keys[0]
        key_id = path.stem.removeprefix("AuthKey_")
    if not path.exists():
        fail(f"{path} doesn't exist")
    issuer = os.environ.get("ASC_ISSUER_ID")
    if not issuer:
        issuer_file = KEYS_DIR.parent / "issuer_id"
        if not issuer_file.exists():
            fail(f"set ASC_ISSUER_ID, or write the issuer ID to {issuer_file}")
        issuer = issuer_file.read_text().strip()
    return path, key_id, issuer


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def der_to_raw(der):
    """An ECDSA signature from openssl (DER: SEQUENCE { INTEGER r, INTEGER s }) as JWS
    expects it: r and s, 32 bytes each."""
    i = 3 if der[1] & 0x80 else 2
    raw = b""
    for _ in range(2):
        length = der[i + 1]
        raw += der[i + 2 : i + 2 + length].lstrip(b"\0").rjust(32, b"\0")
        i += 2 + length
    return raw


_token = None


def token():
    global _token
    now = int(time.time())
    if _token and _token[1] > now + 60:
        return _token[0]
    path, key_id, issuer = api_key()
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    claims = {"iss": issuer, "aud": "appstoreconnect-v1", "iat": now, "exp": now + 1200}
    payload = b64url(json.dumps(claims).encode())
    signing_input = header + b"." + payload
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(path)],
        input=signing_input,
        capture_output=True,
        check=True,
    ).stdout
    _token = ((signing_input + b"." + b64url(der_to_raw(der))).decode(), now + 1200)
    return _token[0]


# --- App Store Connect API ---


def request(method, path, body=None, params=None):
    url = API + path
    if params:
        url += "?" + "&".join(f"{k}={urllib.parse.quote(str(v), safe=',')}" for k, v in params.items())
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token()}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as response:
            raw = response.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        try:
            detail = "\n".join(
                f"  {err.get('title')}: {err.get('detail')}" for err in json.loads(detail)["errors"]
            )
        except (ValueError, KeyError):
            pass
        fail(f"{method} {path} failed ({e.code})\n{detail}")
    return json.loads(raw) if raw else None


def get(path, **params):
    return request("GET", path, params=params)


def resource(type_, id_):
    return {"data": {"type": type_, "id": id_}}


def bundle_id():
    settings = {}
    for name in ("Signing.xcconfig", "Signing.local.xcconfig"):
        path = ROOT / "Config" / name
        if path.exists():
            for line in path.read_text().splitlines():
                m = re.match(r"\s*(BUNDLE_ID_PREFIX)\s*=\s*(\S+)", line)
                if m:
                    settings[m[1]] = m[2]
    prefix = settings.get("BUNDLE_ID_PREFIX", "")
    if not prefix or prefix.startswith("devplaceholder"):
        fail("set BUNDLE_ID_PREFIX in Config/Signing.local.xcconfig")
    return f"{prefix}.hibari.app"


_app = None


def app():
    global _app
    if not _app:
        apps = get("/v1/apps", **{"filter[bundleId]": bundle_id()})["data"]
        if not apps:
            fail(f"no app with the bundle ID {bundle_id()} on App Store Connect")
        _app = apps[0]
    return _app


def versions():
    return get(
        f"/v1/apps/{app()['id']}/appStoreVersions",
        **{"filter[platform]": "IOS", "limit": 20},
    )["data"]


def builds(limit=10):
    return get(
        "/v1/builds",
        **{
            "filter[app]": app()["id"],
            "sort": "-uploadedDate",
            "limit": limit,
            "include": "preReleaseVersion",
        },
    )


# --- project ---


def project_versions():
    text = PBXPROJ.read_text()
    marketing = set(re.findall(r"MARKETING_VERSION = ([^;]+);", text))
    build = set(re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", text))
    if len(marketing) != 1 or len(build) != 1:
        fail(f"targets disagree: MARKETING_VERSION {marketing}, CURRENT_PROJECT_VERSION {build}")
    return marketing.pop(), int(build.pop())


def set_project_versions(marketing, build):
    text = PBXPROJ.read_text()
    text = re.sub(r"MARKETING_VERSION = [^;]+;", f"MARKETING_VERSION = {marketing};", text)
    text = re.sub(r"CURRENT_PROJECT_VERSION = [^;]+;", f"CURRENT_PROJECT_VERSION = {build};", text)
    PBXPROJ.write_text(text)


# --- git ---


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout.rstrip()


def require_clean():
    dirty = [
        line[3:]
        for line in git("status", "--porcelain", "--untracked-files=all").splitlines()
        if not line[3:].startswith("release-notes/")
    ]
    if dirty:
        fail("commit or stash these first, so that the build is HEAD:\n  " + "\n  ".join(dirty))


def tag_release(version_string, build, uploaded_date):
    tag = f"v{version_string}"
    commit_file = ROOT / "build" / f"release-{version_string}-{build}" / "commit"
    if not commit_file.exists():
        print(f"Not tagged: {commit_file.relative_to(ROOT)} (written by upload) doesn't exist. "
              f"Tag the commit build {build} was made from: git tag -a {tag} <commit>")
        return
    commit = commit_file.read_text().strip()
    existing = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", f"{tag}^{{commit}}"],
        cwd=ROOT, capture_output=True, text=True,
    ).stdout.strip()
    if existing == commit:
        print(f"{tag} is already {commit[:7]}")
        return
    if existing:
        print(f"Not tagged: {tag} is {existing[:7]}, but build {build} is {commit[:7]}. "
              f"To move it: git tag -fa {tag} {commit[:7]}")
        return
    git("tag", "-a", tag, commit, "-m",
        f"{version_string} (build {build}) — App Store submission, uploaded {uploaded_date}")
    print(f"Tagged {commit[:7]} as {tag}. Push it: git push origin main {tag}")


# --- commands ---


def cmd_status(args):
    a = app()
    print(f"{a['attributes']['name']} ({a['attributes']['bundleId']}, id {a['id']})")
    print("\nApp Store versions:")
    for v in versions():
        attrs = v["attributes"]
        print(f"  {attrs['versionString']:<8} {attrs['appStoreState']}")
    response = builds()
    trains = {i["id"]: i["attributes"]["version"] for i in response.get("included", [])}
    print("\nBuilds:")
    for b in response["data"]:
        attrs = b["attributes"]
        train = trains.get(b["relationships"]["preReleaseVersion"]["data"]["id"], "?")
        print(f"  {train} ({attrs['version']})  {attrs['processingState']:<11} {attrs['uploadedDate']}")
    marketing, build = project_versions()
    print(f"\nProject: {marketing} ({build})")


def cmd_bump(args):
    require_clean()
    _, current = project_versions()
    uploaded = [int(b["attributes"]["version"]) for b in builds(limit=1)["data"]]
    build = max([current, *uploaded]) + 1
    set_project_versions(args.version, build)
    git("commit", "-q", "-m", f"chore: bump version to {args.version} ({build})",
        str(PBXPROJ.relative_to(ROOT)))
    print(f"Project: {args.version} ({build}), committed")


def cmd_upload(args):
    require_clean()
    marketing, build = project_versions()
    out = ROOT / "build" / f"release-{marketing}-{build}"
    out.mkdir(parents=True, exist_ok=True)
    # For submit, which tags it.
    (out / "commit").write_text(git("rev-parse", "HEAD") + "\n")
    archive = out / "hibari.xcarchive"
    # Signs and uploads as the Apple ID signed in to Xcode, which has the distribution
    # certificate. With the API key (-authenticationKeyPath) xcodebuild signs with a
    # cloud-managed certificate instead, which the key isn't allowed to use.
    auth = ["-allowProvisioningUpdates"]
    export_options = out / "ExportOptions.plist"
    export_options.write_bytes(
        plistlib.dumps(
            {
                "method": "app-store-connect",
                "destination": "upload",
                "signingStyle": "automatic",
                "uploadSymbols": True,
                "manageAppVersionAndBuildNumber": False,
            }
        )
    )
    steps = [
        ("archive", [
            "xcodebuild", "-project", str(ROOT / "hibari.xcodeproj"), "-scheme", "hibari",
            "-configuration", "Release", "-destination", "generic/platform=iOS",
            "-archivePath", str(archive), *auth, "archive",
        ]),
        ("upload", [
            "xcodebuild", "-exportArchive", "-archivePath", str(archive),
            "-exportOptionsPlist", str(export_options), "-exportPath", str(out / "export"), *auth,
        ]),
    ]
    for name, command in steps:
        log = out / f"{name}.log"
        print(f"{name}: {marketing} ({build}) → {log.relative_to(ROOT)}", flush=True)
        with log.open("w") as f:
            if subprocess.run(command, stdout=f, stderr=subprocess.STDOUT).returncode:
                tail = log.read_text().splitlines()[-30:]
                fail(f"{name} failed:\n" + "\n".join(tail))
    print(f"Uploaded {marketing} ({build})")


def wait_for_build(marketing, build, timeout):
    deadline = time.time() + timeout
    while True:
        found = get(
            "/v1/builds",
            **{
                "filter[app]": app()["id"],
                "filter[version]": build,
                "filter[preReleaseVersion.version]": marketing,
            },
        )["data"]
        state = found[0]["attributes"]["processingState"] if found else "NOT_YET_LISTED"
        if state == "VALID":
            return found[0]
        if state in ("FAILED", "INVALID"):
            fail(f"build {marketing} ({build}) is {state}")
        if time.time() > deadline:
            fail(f"build {marketing} ({build}) is still {state} after {timeout // 60} minutes")
        print(f"  build {marketing} ({build}): {state}", flush=True)
        time.sleep(30)


def editable_version(version_string):
    all_versions = versions()
    for v in all_versions:
        if v["attributes"]["versionString"] == version_string:
            return v
    for v in all_versions:
        if v["attributes"]["appStoreState"] in EDITABLE_STATES:
            print(f"Renaming version {v['attributes']['versionString']} to {version_string}")
            return request(
                "PATCH",
                f"/v1/appStoreVersions/{v['id']}",
                {"data": {"type": "appStoreVersions", "id": v["id"],
                          "attributes": {"versionString": version_string}}},
            )["data"]
    print(f"Creating version {version_string}")
    return request(
        "POST",
        "/v1/appStoreVersions",
        {"data": {
            "type": "appStoreVersions",
            "attributes": {"platform": "IOS", "versionString": version_string},
            "relationships": {"app": resource("apps", app()["id"])},
        }},
    )["data"]


def app_locales():
    """The localizations of the version on the store, which a new version starts with."""
    for v in versions():
        localizations = get(f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations")["data"]
        if localizations:
            return sorted(l["attributes"]["locale"] for l in localizations)
    fail("no version has localizations to copy")


def read_notes(version_string, locales):
    notes = {}
    missing = []
    for locale in locales:
        path = NOTES_DIR / version_string / f"{locale}.txt"
        if path.exists():
            notes[locale] = path.read_text().strip()
        else:
            missing.append(str(path.relative_to(ROOT)))
    if missing:
        fail("release notes missing: " + ", ".join(missing))
    for locale, text in notes.items():
        if len(text) > 4000:
            fail(f"release notes for {locale} are over 4000 characters")
    return notes


def cmd_prepare(args):
    marketing, build = project_versions()
    if marketing != args.version:
        fail(f"the project is at {marketing}, not {args.version} (run bump and upload first)")
    notes = read_notes(args.version, app_locales())
    uploaded = wait_for_build(marketing, build, args.timeout)
    version = editable_version(args.version)

    localizations = get(f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations")["data"]
    for localization in localizations:
        locale = localization["attributes"]["locale"]
        if locale not in notes:
            fail(f"release notes missing: release-notes/{args.version}/{locale}.txt")
        request(
            "PATCH",
            f"/v1/appStoreVersionLocalizations/{localization['id']}",
            {"data": {"type": "appStoreVersionLocalizations", "id": localization["id"],
                      "attributes": {"whatsNew": notes[locale]}}},
        )
        print(f"What's New ({locale}) set")

    request(
        "PATCH",
        f"/v1/appStoreVersions/{version['id']}/relationships/build",
        resource("builds", uploaded["id"]),
    )
    print(f"Version {args.version} uses build {build}")


def cmd_submit(args):
    version = next((v for v in versions() if v["attributes"]["versionString"] == args.version), None)
    if not version:
        fail(f"no version {args.version} on App Store Connect")
    state = version["attributes"]["appStoreState"]
    if state not in EDITABLE_STATES:
        fail(f"version {args.version} is {state}")

    # Reuse a submission that was started but not sent (e.g. from the web).
    pending = get(
        "/v1/reviewSubmissions",
        **{"filter[app]": app()["id"], "filter[platform]": "IOS", "filter[state]": "READY_FOR_REVIEW"},
    )["data"]
    if pending:
        submission = pending[0]
    else:
        submission = request(
            "POST",
            "/v1/reviewSubmissions",
            {"data": {"type": "reviewSubmissions", "attributes": {"platform": "IOS"},
                      "relationships": {"app": resource("apps", app()["id"])}}},
        )["data"]
    items = get(f"/v1/reviewSubmissions/{submission['id']}/items", include="appStoreVersion")["data"]
    has_version = any(
        (i["relationships"].get("appStoreVersion", {}).get("data") or {}).get("id") == version["id"]
        for i in items
    )
    if not has_version:
        request(
            "POST",
            "/v1/reviewSubmissionItems",
            {"data": {"type": "reviewSubmissionItems", "relationships": {
                "reviewSubmission": resource("reviewSubmissions", submission["id"]),
                "appStoreVersion": resource("appStoreVersions", version["id"]),
            }}},
        )
    request(
        "PATCH",
        f"/v1/reviewSubmissions/{submission['id']}",
        {"data": {"type": "reviewSubmissions", "id": submission["id"],
                  "attributes": {"submitted": True}}},
    )
    print(f"Submitted {args.version} for review")

    selected = get(f"/v1/appStoreVersions/{version['id']}/build")["data"]
    if selected:
        attrs = selected["attributes"]
        tag_release(args.version, attrs["version"], attrs["uploadedDate"][:10])


def cmd_release(args):
    # Fail on missing notes now rather than after a 20-minute build and upload.
    read_notes(args.version, app_locales())
    cmd_bump(args)
    cmd_upload(args)
    cmd_prepare(args)
    if args.submit:
        cmd_submit(args)
    else:
        print(f"Not submitted: run `scripts/release.py submit {args.version}` to send it for review")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status").set_defaults(func=cmd_status)
    p = sub.add_parser("bump")
    p.add_argument("version")
    p.set_defaults(func=cmd_bump)
    sub.add_parser("upload").set_defaults(func=cmd_upload)
    for name, func in (("prepare", cmd_prepare), ("release", cmd_release)):
        p = sub.add_parser(name)
        p.add_argument("version")
        p.add_argument("--timeout", type=int, default=45 * 60,
                       help="seconds to wait for the build to finish processing")
        if name == "release":
            p.add_argument("--submit", action="store_true", help="also submit it for review")
        p.set_defaults(func=func)
    p = sub.add_parser("submit")
    p.add_argument("version")
    p.set_defaults(func=cmd_submit)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
