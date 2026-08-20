#!/usr/bin/env python3
"""Pre-generate the example-sentence audio for the most common words.

WHY THIS EXISTS
---------------
The app can already speak an example sentence: Voice.speak() takes any text,
and the tts Edge Function caches every clip in Supabase Storage keyed by
language + voice + model + dictionary + text. That cache is SHARED — the first
learner to meet a word pays the ElevenLabs synthesis, and every learner after
them, forever, gets a free cache hit.

Which means the first learner pays for everyone, at a cold-start latency they
did not ask for. This tool moves that cost to a developer running a script:
one deliberate spend, up front, and from then on the sentence audio is
instant for everybody.

WHAT IT SPENDS
--------------
ElevenLabs credits, once per distinct sentence. English goes through
eleven_flash_v2 at roughly half a credit per character. `plan` prints the
estimate and nothing is spent until `run`.

THE ADMIN TOKEN
---------------
The tts function caps each caller at 60,000 characters a day, which is correct
for an app and useless for a bulk run. TTS_ADMIN_TOKEN skips that cap and
nothing else — same cache, same voice, same model. Set it as an Edge Function
secret and export it here. Without it this tool will run into the daily budget
after a few hundred sentences and stop, which is the safe failure.

USAGE
-----
    export SUPABASE_ANON_KEY=...        # public; also in supabase_config.dart
    export TTS_ADMIN_TOKEN=...          # the secret set in Supabase

    python tools/warm_audio.py plan --top 8000
    python tools/warm_audio.py run  --top 8000
    python tools/warm_audio.py run  --top 8000     # resumes; already-done is free
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORDS = ROOT / "assets" / "words.json"
STATE = ROOT / "tools" / ".warm_audio_state.json"

# Kept in step with the Edge Function. A sentence over this is skipped rather
# than truncated: half a sentence is worse than no sentence.
MAX_TEXT_LEN = 400

# Flash v2 bills at about half a credit per character for English.
CREDITS_PER_CHAR = 0.5

DEFAULT_URL = "https://fzhguqoodojugeuyosnj.supabase.co"


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def load_words() -> list[dict]:
    if not WORDS.exists():
        die(f"{WORDS} not found")
    data = json.loads(WORDS.read_text(encoding="utf-8"))
    return data["words"] if isinstance(data, dict) and "words" in data else data


def selection(words: list[dict], top: int, per_word: int = 1
              ) -> list[tuple[str, str, str]]:
    """(word id, headword, English example) for the [top] most common words.

    Ordered by frequency rank because that is the order learners actually meet
    words in, so a partial run still covers the words most people will hear.
    Sentences are English whatever the learner's own language: English is what
    is being learned, and the native-language sentence is a reading aid.
    """
    ranked = sorted(words, key=lambda e: e.get("freqRank") or 10**9)
    out: list[tuple[str, str, str]] = []
    seen: set[str] = set()
    # One sentence per word by default. Every entry now carries two, so
    # defaulting to both would quietly double the bill against the number the
    # `plan` estimate was approved on — and the second sentence is the one
    # fewer learners reach.
    fields = ("example", "example2")[:max(1, min(2, per_word))]
    for e in ranked[:top]:
        gloss = (e.get("gloss") or {}).get("en") or {}
        for field in fields:
            text = ((gloss.get(field) or {}) or {}).get("text") or ""
            text = text.strip()
            if not text or len(text) > MAX_TEXT_LEN:
                continue
            # The cache is keyed by TEXT, so a sentence shared between two
            # entries is one clip and must only be paid for once.
            if text in seen:
                continue
            seen.add(text)
            out.append((e["id"], e["word"], text))
    return out


def read_state() -> set[str]:
    if not STATE.exists():
        return set()
    try:
        return set(json.loads(STATE.read_text(encoding="utf-8"))["done"])
    except Exception:
        return set()


def write_state(done: set[str]) -> None:
    STATE.write_text(json.dumps({"done": sorted(done)}), encoding="utf-8")


def cmd_plan(args: argparse.Namespace) -> None:
    items = selection(load_words(), args.top, args.sentences)
    done = read_state()
    todo = [t for t in items if t[2] not in done]
    chars = sum(len(t[2]) for t in todo)
    print(f"words considered   : {args.top:,}")
    print(f"sentences per word : {args.sentences}")
    print(f"distinct sentences : {len(items):,}")
    print(f"already warmed     : {len(items) - len(todo):,}")
    print(f"to synthesize      : {len(todo):,}  ({chars:,} characters)")
    print(f"estimated credits  : {chars * CREDITS_PER_CHAR:,.0f}")
    print("\nEstimate, not a quote — anything already in the Storage cache from")
    print("normal app use costs nothing, and this cannot tell which until it asks.")
    print("Run `run` to start; nothing is spent until then.")


def synth(base: str, anon: str, admin: str, text: str) -> tuple[bool, bool, str]:
    """Returns (ok, was_cached, detail)."""
    req = urllib.request.Request(
        f"{base}/functions/v1/tts",
        data=json.dumps({"text": text, "lang": "en"}).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {anon}",
            "apikey": anon,
            "x-admin-token": admin,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            body = json.loads(r.read().decode("utf-8"))
            return True, bool(body.get("cached")), ""
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:180]
        return False, False, f"HTTP {e.code}: {detail}"
    except Exception as e:  # noqa: BLE001 - network, and it all reads the same
        return False, False, str(e)


def cmd_run(args: argparse.Namespace) -> None:
    anon = os.environ.get("SUPABASE_ANON_KEY", "")
    admin = os.environ.get("TTS_ADMIN_TOKEN", "")
    if not anon:
        die("SUPABASE_ANON_KEY is not set (it is the public key in "
            "lib/services/supabase_config.dart)")
    if not admin:
        die("TTS_ADMIN_TOKEN is not set. Without it the daily 60,000-character "
            "budget applies and this will stop after a few hundred sentences.")
    base = os.environ.get("SUPABASE_URL", DEFAULT_URL).rstrip("/")

    items = selection(load_words(), args.top, args.sentences)
    done = read_state()
    todo = [t for t in items if t[2] not in done]
    if not todo:
        print("Nothing to do — everything selected is already warmed.")
        return

    chars = sum(len(t[2]) for t in todo)
    print(f"{len(todo):,} sentences, {chars:,} characters, "
          f"about {chars * CREDITS_PER_CHAR:,.0f} credits.")
    if not args.yes:
        if input("Spend that now? [y/N] ").strip().lower() not in ("y", "yes"):
            print("aborted.")
            return

    made = cached = failed = 0
    started = time.time()

    def one(item: tuple[str, str, str]) -> tuple[str, bool, bool, str]:
        _, _, text = item
        ok, was_cached, detail = synth(base, anon, admin, text)
        return text, ok, was_cached, detail

    # Four at a time. The function is doing a network round trip to ElevenLabs
    # per miss; more concurrency mostly buys rate-limit errors, and this is not
    # a job anyone is waiting on.
    try:
        with ThreadPoolExecutor(max_workers=4) as pool:
            for i, (text, ok, was_cached, detail) in enumerate(
                    pool.map(one, todo), start=1):
                if ok:
                    done.add(text)
                    if was_cached:
                        cached += 1
                    else:
                        made += 1
                else:
                    failed += 1
                    if failed <= 5:
                        print(f"  ! {detail}")
                if i % 100 == 0 or i == len(todo):
                    write_state(done)
                    rate = i / max(time.time() - started, 1e-9)
                    print(f"  {i:,}/{len(todo):,}  new {made:,}  "
                          f"cached {cached:,}  failed {failed:,}  "
                          f"({rate:.1f}/s)")
    except KeyboardInterrupt:
        print("\ninterrupted — progress saved, re-run to continue.")
    finally:
        write_state(done)

    spent = sum(len(t[2]) for t in todo if t[2] in done) * CREDITS_PER_CHAR
    print(f"\nnew clips {made:,}, already cached {cached:,}, failed {failed:,}")
    print(f"roughly {spent:,.0f} credits of synthesis requested.")
    if failed:
        print("Re-run to retry the failures; anything that succeeded is skipped.")


def cmd_selftest(args: argparse.Namespace) -> None:
    """Checks the selection rules against hand-built input.

    Selection is the part with judgement in it — which sentences, in what
    order, how many per word — and it is the part that decides what gets
    charged. The HTTP call is plumbing.
    """
    def word(wid, rank, ex, ex2=None, long_first=False):
        gloss = {"correct": "x", "distractors": ["a", "b"],
                 "example": {"text": "y" * 500 if long_first else ex}}
        if ex2 is not None:
            gloss["example2"] = {"text": ex2}
        return {"id": wid, "word": wid, "freqRank": rank, "gloss": {"en": gloss}}

    fails = []

    def check(label, got, want):
        if got != want:
            fails.append(f"{label}\n     got  {got}\n     want {want}")

    corpus = [
        word("c", 300, "Third sentence.", "Third again."),
        word("a", 100, "First sentence.", "First again."),
        word("b", 200, "Second sentence.", "Second again."),
    ]

    # Frequency order, so a partial run covers the commonest words.
    check("orders by frequency rank",
          [t[0] for t in selection(corpus, 3)], ["a", "b", "c"])

    # One sentence per word unless asked otherwise.
    check("one sentence per word by default",
          [t[2] for t in selection(corpus, 1)], ["First sentence."])
    check("two when asked",
          [t[2] for t in selection(corpus, 1, per_word=2)],
          ["First sentence.", "First again."])

    # The cache is keyed by text, so a sentence shared by two entries must be
    # paid for once.
    dupes = [word("x", 1, "Shared sentence."), word("y", 2, "Shared sentence.")]
    check("deduplicates identical sentences",
          [t[2] for t in selection(dupes, 2)], ["Shared sentence."])

    # Over the function's limit: skipped, not truncated. Half a sentence is
    # worse than no sentence, and the function would reject it anyway.
    over = [word("z", 1, "", long_first=True)]
    check("skips anything over MAX_TEXT_LEN", selection(over, 1), [])

    # Missing or blank examples are not an error, just nothing to do.
    blank = [{"id": "n", "word": "n", "freqRank": 1, "gloss": {"en": {}}}]
    check("tolerates a word with no example", selection(blank, 1), [])

    if fails:
        for f in fails:
            print("FAIL " + f)
        sys.exit(1)
    print(f"selection rules: {6 - len(fails)}/6 ok")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("selftest").set_defaults(fn=cmd_selftest)
    for name, fn in (("plan", cmd_plan), ("run", cmd_run)):
        p = sub.add_parser(name)
        p.add_argument("--top", type=int, default=8000,
                       help="how many of the most common words to cover")
        p.add_argument("--sentences", type=int, default=1, choices=(1, 2),
                       help="example sentences per word (default 1)")
        if name == "run":
            p.add_argument("--yes", action="store_true",
                           help="skip the confirmation prompt")
        p.set_defaults(fn=fn)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
