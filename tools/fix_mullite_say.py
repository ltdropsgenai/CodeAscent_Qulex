#!/usr/bin/env python3
"""Give mullite a respelling. Run from the repo root.

    python tools/fix_mullite_say.py

Build 45 says "mullite" and it is heard wrong; it should be MUL-ite — "mull"
as in to mull something over, then "ite" rhyming with white.

Verified before writing, not after. Four candidates went through the live tts
function and were judged by ear:

    mullite     the shipped reading, wrong
    mull-ight   wrong
    mull-ite    wrong
    mullight    RIGHT

Note which won. "parra-taupe" kept its hyphen and "mullight" loses one, so the
hyphen is not the variable — what matters is whether each piece has exactly one
reading. "ight" can only be light/night/right; "ite" can be -eet or -it.

Generation goes 4 -> 5 rather than being amended in place, because generation 4
is what build 45 shipped. Clients compare with `>`, so a number that has been
released can never be reused.
"""
import collections
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORDS = ROOT / "assets" / "words.json"

BEFORE = "070b1b19a23af555db9ed11c8d35007d5c3276be0f73ce29bdb6668d24f2bd22"
EXPECT = "ff9387a8cf174fcdf0287cfe39723305f25d8138d7f5bc04ff72895274ed00c8"
WORD, SAY = "mullite", "mullight"


def main():
    if not WORDS.exists():
        sys.exit(f"run this from the repo root — cannot find {WORDS}")
    raw = WORDS.read_bytes()
    have = hashlib.sha256(raw).hexdigest()
    if have == EXPECT:
        sys.exit("already applied.")
    if have != BEFORE:
        sys.exit(f"unexpected starting file.\n  expected {BEFORE}\n  found    {have}\n"
                 "This expects the catalogue build 45 shipped. Nothing written.")

    words = json.loads(raw, object_pairs_hook=collections.OrderedDict)
    # `say` sits fifth, after pos — match the ten entries already there.
    pos = list(next(w for w in words if w.get("say")).keys()).index("say")

    hits = 0
    for i, w in enumerate(words):
        if w["word"].lower() != WORD:
            continue
        if w.get("say"):
            sys.exit(f"{WORD} already carries say={w['say']!r}")
        items = list(w.items())
        items.insert(pos, ("say", SAY))
        words[i] = collections.OrderedDict(items)
        hits += 1
    if hits != 1:
        sys.exit(f"expected exactly one {WORD} entry, found {hits}")

    out = json.dumps(words, separators=(", ", ": "), ensure_ascii=False).encode("utf-8")
    sha = hashlib.sha256(out).hexdigest()
    if sha != EXPECT:
        sys.exit(f"refusing to write — hash mismatch.\n  expected {EXPECT}\n  produced {sha}")

    WORDS.write_bytes(out)
    print(f"{WORD}: say -> {SAY}")
    print(f"sha256 {sha}")
    print("matches kBundledCatalogueSha256. Run flutter test next.")


if __name__ == "__main__":
    main()
