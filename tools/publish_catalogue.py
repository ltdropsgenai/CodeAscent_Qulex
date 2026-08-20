#!/usr/bin/env python3
"""Publish assets/words.json to installed apps, without a store release.

    python tools/publish_catalogue.py status
    python tools/publish_catalogue.py publish
    python tools/publish_catalogue.py disable      # roll back to the bundled list
    python tools/publish_catalogue.py enable
    python tools/publish_catalogue.py prune        # delete superseded payloads

Needs CATALOGUE_ADMIN_TOKEN in the environment. That token can write one
storage bucket and nothing else; the service-role key stays inside the
catalogue-admin Edge Function.

HOW A CONTENT PUSH WORKS

1. Edit assets/words.json.
2. Bump kBundledCatalogueGeneration in lib/data/catalogue_ota.dart, in the same
   commit. Clients compare the published generation against the constant
   compiled into their own binary and only take a HIGHER one, so this number is
   what makes the push visible — and what makes a later store build reclaim the
   downloaded copy.
3. Run `publish`. It gzips the catalogue, uploads it under a name derived from
   the generation, then writes manifest.json last.
4. Installed apps pick it up on their next background check (at most two
   hours, plus up to a minute of CDN cache on the manifest) and use it from the
   following cold start. Nothing swaps mid-session.

WHAT THIS DELIBERATELY WILL NOT DO

- Publish a generation that does not match the constant in the source tree. A
  mismatch means the repo and the bucket disagree about what the current
  catalogue is, and the next person to look would have no way to tell which is
  right.
- Publish a catalogue this app cannot parse. Every entry is decoded first,
  against the same required fields Word.fromJson enforces. A SHA-256 proves the
  bytes arrived intact; it says nothing about whether they mean anything, and
  the client's only defence against unparseable content is to throw the
  download away and fall back — which works, but silently costs every learner a
  25MB download for nothing.
- Overwrite a live payload. Generations are content-addressed by name.

ROLLING BACK. `disable` flips one flag in the manifest. Clients delete their
downloaded catalogue and go back to the word list in their binary. No build, no
new payload, no version bump.

It is not instant, and it is worth knowing the two delays before you need them:
manifest.json is served with cache-control 60, so the CDN can keep handing out
the old one for up to a minute, and a client only looks every two hours. Verify
a rollback by reading the public manifest back, not by watching a device.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORDS = ROOT / "assets" / "words.json"
OTA_SOURCE = ROOT / "lib" / "data" / "catalogue_ota.dart"

PROJECT_URL = os.environ.get(
    "SUPABASE_URL", "https://fzhguqoodojugeuyosnj.supabase.co"
).rstrip("/")
FUNCTION_URL = f"{PROJECT_URL}/functions/v1/catalogue-admin"
PUBLIC_BASE = f"{PROJECT_URL}/storage/v1/object/public/catalogue"

# Public by design (RLS is what protects data, not this) and already shipped in
# every binary — see lib/services/supabase_config.dart. Present only because
# the functions gateway wants an Authorization header.
ANON_KEY = os.environ.get(
    "SUPABASE_ANON_KEY",
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
    "eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ6aGd1cW9vZG9qdWdldXlvc25qIiwicm9sZSI6"
    "ImFub24iLCJpYXQiOjE3ODYzMTE1MTUsImV4cCI6MjEwMTg4NzUxNX0."
    "j028Mj6fKsw-9jJugUqNGMgMXWrWSu5iTpu3Dsk7JrA",
)

TIMEOUT = 120


def die(msg: str) -> "None":
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(1)


def admin_token() -> str:
    tok = os.environ.get("CATALOGUE_ADMIN_TOKEN", "").strip()
    if not tok:
        die(
            "CATALOGUE_ADMIN_TOKEN is not set.\n"
            "  PowerShell:  $env:CATALOGUE_ADMIN_TOKEN = '...'\n"
            "  bash:        export CATALOGUE_ADMIN_TOKEN=...\n"
            "It must match the secret set in Supabase "
            "(Project Settings -> Edge Functions -> Secrets)."
        )
    return tok


def call(action: str, **payload) -> dict:
    body = json.dumps({"action": action, **payload}).encode()
    req = urllib.request.Request(
        FUNCTION_URL,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {ANON_KEY}",
            "x-admin-token": admin_token(),
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as res:
            return json.loads(res.read().decode())
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        if e.code == 403:
            die(
                "the function refused the admin token (403).\n"
                "Either CATALOGUE_ADMIN_TOKEN is wrong, or the secret was never "
                "set in Supabase — the function fails closed when it is unset."
            )
        die(f"{action} failed: HTTP {e.code} {detail}")
    except urllib.error.URLError as e:
        die(f"{action} failed: {e.reason}")
    raise AssertionError("unreachable")


def bundled_generation() -> int:
    """Reads kBundledCatalogueGeneration out of the Dart source.

    Parsed rather than duplicated in a config file so there is exactly one
    place the number lives — the place the compiler reads.
    """
    if not OTA_SOURCE.exists():
        die(f"cannot find {OTA_SOURCE}")
    m = re.search(
        r"^const\s+int\s+kBundledCatalogueGeneration\s*=\s*(\d+)\s*;",
        OTA_SOURCE.read_text(encoding="utf-8"),
        re.M,
    )
    if not m:
        die(f"could not find kBundledCatalogueGeneration in {OTA_SOURCE}")
    return int(m.group(1))


def check_parseable(raw: bytes) -> int:
    """Decodes the catalogue the way the app does, and returns the entry count.

    The client verifies a SHA-256, which catches a corrupted transfer and
    nothing else. A file that is byte-for-byte what was published can still be
    missing a field this build requires, and the app's only recourse then is to
    discard it and fall back — after a 25MB download, for every learner. This
    is where that gets caught instead.
    """
    try:
        items = json.loads(raw)
    except json.JSONDecodeError as e:
        die(f"assets/words.json is not valid JSON: {e}")
    if not isinstance(items, list) or not items:
        die("assets/words.json must be a non-empty JSON array")
    # Mirrors Word.fromJson / Gloss.fromJson: these are the casts that throw.
    required = ("id", "word", "pos", "freqRank", "difficulty", "tags", "gloss")
    seen_ids: set[str] = set()
    for i, w in enumerate(items):
        if not isinstance(w, dict):
            die(f"entry {i} is not an object")
        for f in required:
            if f not in w or w[f] is None:
                die(f"entry {i} ({w.get('word', '?')}) has no {f!r}")
        if not isinstance(w["gloss"], dict) or not w["gloss"]:
            die(f"entry {i} ({w['word']}) has an empty gloss")
        for lang, g in w["gloss"].items():
            if not isinstance(g, dict):
                die(f"entry {i} ({w['word']}) gloss[{lang}] is not an object")
            for f in ("correct", "distractors", "example"):
                if f not in g:
                    die(f"entry {i} ({w['word']}) gloss[{lang}] has no {f!r}")
            if not isinstance(g["example"], dict) or "text" not in g["example"]:
                die(f"entry {i} ({w['word']}) gloss[{lang}].example has no text")
        wid = w["id"]
        if wid in seen_ids:
            # Progress is keyed by id. Duplicates would make two different
            # words share one learner's review schedule.
            die(f"duplicate id {wid!r} at entry {i}")
        seen_ids.add(wid)
    return len(items)


def cmd_status(_args) -> None:
    out = call("status")
    manifest = out.get("manifest")
    print(f"bundled generation (source tree): {bundled_generation()}")
    if not manifest:
        print("published: nothing yet")
    else:
        state = "DISABLED" if manifest.get("disabled") else "live"
        print(
            f"published: generation {manifest.get('generation')} [{state}] "
            f"{manifest.get('path')} "
            f"{manifest.get('bytes'):,} bytes "
            f"sha256={str(manifest.get('sha256'))[:16]}…"
        )
        if manifest.get("minAppBuild"):
            print(f"  requires build >= {manifest['minAppBuild']}")
    print("bucket:")
    for f in out.get("files", []):
        size = f.get("size")
        print(f"  {f['name']:<28} {size if size is None else f'{size:,}':>12}  {f.get('updated_at')}")


def cmd_publish(args) -> None:
    if not WORDS.exists():
        die(f"cannot find {WORDS}")
    generation = bundled_generation()
    raw = WORDS.read_bytes()

    count = check_parseable(raw)
    sha = hashlib.sha256(raw).hexdigest()
    # mtime=0 so the same catalogue always gzips to the same bytes. A publish
    # that changes nothing should be visibly a no-op, not a new blob.
    blob = gzip.compress(raw, compresslevel=9, mtime=0)
    path = f"words-g{generation}.json.gz"

    print(f"catalogue     {count:,} entries, {len(raw):,} bytes")
    print(f"gzipped       {len(blob):,} bytes ({len(blob) * 100 // len(raw)}%)")
    print(f"sha256        {sha}")
    print(f"generation    {generation}")
    if args.min_app_build:
        print(f"requires build >= {args.min_app_build}")

    live = call("status").get("manifest") or {}
    if live.get("generation") == generation and live.get("sha256") == sha \
            and not live.get("disabled"):
        print("\nalready published, unchanged. Nothing to do.")
        return
    # The mistake this exists for. Publishing the SAME generation number with
    # DIFFERENT bytes looks like it works — the upload succeeds, the manifest
    # updates, the CDN serves it — and reaches nobody at all.
    #
    # Clients record the generation they installed and take an update only when
    # published > installed (CatalogueOta._shouldTake). Anything already on
    # generation N therefore ignores a second, different generation N forever,
    # and a client freshly built from this tree bundles it anyway. Meanwhile the
    # previous payload for that generation has been overwritten, so a client
    # part-way through downloading the old one fails its sha256 check.
    #
    # This happened on 20 Aug 2026: 15,000 new example sentences were published
    # as generation 1 over the top of generation 1, because the source constant
    # had not been bumped. The upload was clean and the effect was zero.
    if isinstance(live.get("generation"), int) \
            and live["generation"] == generation \
            and live.get("sha256") != sha:
        die(
            f"generation {generation} is already published with different "
            f"content.\n"
            f"  live sha256   {live.get('sha256')}\n"
            f"  this tree     {sha}\n"
            "No client would ever take this: an install already on generation "
            f"{generation} only accepts something NEWER, and a fresh build "
            "bundles this content anyway. Bump kBundledCatalogueGeneration in "
            "lib/data/catalogue_ota.dart, commit, and publish that instead."
        )
    if isinstance(live.get("generation"), int) and live["generation"] > generation:
        die(
            f"generation {live['generation']} is already published, which is "
            f"newer than {generation} in the source tree. Publishing would be a "
            "downgrade that no client would take. Bump "
            "kBundledCatalogueGeneration first."
        )
    if not args.yes:
        reach = "every installed app" if not args.min_app_build else \
            f"every installed app at build {args.min_app_build} or newer"
        ans = input(f"\nPublish generation {generation} to {reach}? [y/N] ")
        if ans.strip().lower() not in ("y", "yes"):
            print("aborted.")
            return

    print("\nsigning upload…")
    signed = call("sign_upload", path=path)
    print("uploading payload…")
    put = urllib.request.Request(
        signed["signedUrl"],
        data=blob,
        headers={
            "Content-Type": "application/gzip",
            "x-upsert": "true",
        },
        method="PUT",
    )
    try:
        with urllib.request.urlopen(put, timeout=TIMEOUT) as res:
            res.read()
    except urllib.error.HTTPError as e:
        die(f"upload failed: HTTP {e.code} {e.read().decode(errors='replace')}")
    except urllib.error.URLError as e:
        die(f"upload failed: {e.reason}")

    manifest = {
        "schema": 1,
        "generation": generation,
        "minAppBuild": args.min_app_build,
        "path": path,
        "bytes": len(raw),
        "sha256": sha,
        "disabled": False,
    }
    print("publishing manifest…")
    call("set_manifest", manifest=manifest)

    print("verifying from the public CDN…")
    verify(manifest)
    print(f"\npublished. generation {generation} is live.")
    print("Installed apps pick it up within two hours and use it from their")
    print("next cold start. `python tools/publish_catalogue.py disable` rolls back.")


def verify(expected: dict) -> None:
    """Reads back exactly what a phone would read, and checks it end to end.

    Not a formality. Every prior step talked to the Storage API through the
    admin function; this is the only one that exercises the path the app
    actually uses, which is a different host, a different auth model and a CDN
    in between.
    """
    try:
        with urllib.request.urlopen(f"{PUBLIC_BASE}/manifest.json", timeout=30) as r:
            got = json.loads(r.read().decode())
    except Exception as e:  # noqa: BLE001 - any failure here is fatal alike
        die(f"could not read back manifest.json: {e}")
    for k in ("generation", "path", "bytes", "sha256"):
        if got.get(k) != expected[k]:
            die(f"manifest read back with {k}={got.get(k)!r}, expected {expected[k]!r}")

    req = urllib.request.Request(
        f"{PUBLIC_BASE}/{expected['path']}",
        headers={"Accept-Encoding": "identity"},
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            payload = r.read()
    except Exception as e:  # noqa: BLE001
        die(f"could not read back {expected['path']}: {e}")
    try:
        inflated = gzip.decompress(payload)
    except OSError as e:
        die(f"published payload is not valid gzip: {e}")
    if len(inflated) != expected["bytes"]:
        die(f"published payload inflates to {len(inflated):,} bytes, "
            f"manifest says {expected['bytes']:,}")
    actual = hashlib.sha256(inflated).hexdigest()
    if actual != expected["sha256"]:
        die(f"published payload hashes to {actual}, manifest says {expected['sha256']}")
    print(f"  manifest and {len(inflated):,} bytes of catalogue both check out")


def cmd_disable(args) -> None:
    out = call("disable", disabled=not args.enable)
    m = out.get("manifest", {})
    if args.enable:
        print(f"generation {m.get('generation')} is live again.")
    else:
        print(f"generation {m.get('generation')} is withdrawn.")
        print("Clients delete their copy and fall back to the bundled word list")
        print("on their next check. Allow up to a minute for the CDN to stop")
        print("serving the old manifest, then up to two hours per device.")


def cmd_prune(_args) -> None:
    out = call("prune")
    removed = out.get("removed", [])
    if not removed:
        print("nothing to prune.")
        return
    print(f"kept {out.get('kept')}")
    for name in removed:
        print(f"removed {name}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status", help="what is published right now").set_defaults(
        func=cmd_status)

    p = sub.add_parser("publish", help="push assets/words.json over the air")
    p.add_argument("--yes", "-y", action="store_true", help="skip the prompt")
    p.add_argument(
        "--min-app-build", type=int, default=0,
        help="withhold this catalogue from builds older than this. Use when the "
             "content needs code an older build does not have.")
    p.set_defaults(func=cmd_publish)

    d = sub.add_parser("disable", help="roll back to the bundled catalogue")
    d.add_argument("--enable", action="store_true", help="undo a disable")
    d.set_defaults(func=cmd_disable)

    sub.add_parser("enable", help="undo a disable").set_defaults(
        func=lambda a: cmd_disable(argparse.Namespace(enable=True)))

    sub.add_parser("prune", help="delete superseded payloads").set_defaults(
        func=cmd_prune)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
