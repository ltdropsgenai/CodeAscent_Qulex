#!/usr/bin/env python3
"""Respell the four French loanwords that took a second attempt.

    python tools/fix_french_says_2.py     # after tools/fix_french_says.py

Chained off the first script by hash, so running them out of order is refused
rather than half-applied.

WHAT THE SECOND LISTENING SETTLED

    tapenade      tappenahd     over tahpuhnahd, and over tappuhnahd in round 1
    chocolatier   chocolateer   over chokolatteer, and over chokuhluhteer
    grimpeur      grimpurr      over grampur, and over grimpur
    cuirassier    kwirrasseer   over kweeruhseer, and over kwiruhseer

A pattern worth keeping: in three of the four, the winner is the spelling that
stays CLOSEST to the headword and changes only the ending. `chocolateer` is
`chocolate` + `er`. `grimpurr` is `grimpe` with the vowel spelled out. The
respellings that tried to spell out every syllable phonetically - tahpuhnahd,
chokuhluhteer, kweeruhseer - all lost. The engine reads ordinary English
spelling well; what it cannot do is guess a French ending. Change the ending
and leave the rest alone.

STILL UNFIXED, deliberately absent from this file:

    repechage    rep-uh-SHAHZH   4 candidates failed
    brevet       bruh-VET        3 candidates failed
    chalumeau    SHAL-uh-moh     3 candidates failed
    panade       puh-NAHD        3 candidates failed

All four are stress problems rather than vowel problems, which is the one thing
a respelling is worst at: there is no English spelling that means "put the
accent here". They stay unrespelled and are therefore spoken as written, which
is where they already were. A wrong `say` would be worse - it beats every other
rule in the engine and nothing downstream questions it.
"""
import collections
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORDS = ROOT / "assets" / "words.json"

BEFORE = "0867541c212ba4c70aa020678d2a58dcff29ad787a763681871394aa446c8ee7"
EXPECT = "431a836e2b98dc1ca53c1fd4beb87a431d9d15bf2fce43705c83375a35d5057c"

SAY = {
    "tapenade":    "tappenahd",
    "chocolatier": "chocolateer",
    "grimpeur":    "grimpurr",
    "cuirassier":  "kwirrasseer",
}


def main():
    if not WORDS.exists():
        sys.exit(f"run this from the repo root — cannot find {WORDS}")
    raw = WORDS.read_bytes()
    have = hashlib.sha256(raw).hexdigest()
    if have == EXPECT:
        sys.exit("already applied.")
    if have != BEFORE:
        sys.exit(f"unexpected starting file.\n  expected {BEFORE}\n  found    {have}\n"
                 "Run tools/fix_french_says.py first. Nothing written.")

    words = json.loads(raw, object_pairs_hook=collections.OrderedDict)
    pos = list(next(w for w in words if w.get("say")).keys()).index("say")

    done = []
    for i, w in enumerate(words):
        key = w["word"].lower()
        if key not in SAY:
            continue
        if w.get("say"):
            sys.exit(f"{key} already carries say={w['say']!r}. Nothing written.")
        items = list(w.items())
        items.insert(pos, ("say", SAY[key]))
        words[i] = collections.OrderedDict(items)
        done.append(key)

    missing = sorted(set(SAY) - set(done))
    if missing:
        sys.exit(f"not found in the catalogue: {missing}. Nothing written.")

    out = json.dumps(words, separators=(", ", ": "), ensure_ascii=False).encode("utf-8")
    sha = hashlib.sha256(out).hexdigest()
    if sha != EXPECT:
        sys.exit(f"refusing to write — hash mismatch.\n  expected {EXPECT}\n  produced {sha}")

    WORDS.write_bytes(out)
    for k in sorted(done):
        print(f"  {k:<14} say -> {SAY[k]}")
    print(f"\n{len(done)} respellings applied — 21 in this pass, 39 in the catalogue")
    print(f"sha256 {sha}")
    print("matches kBundledCatalogueSha256. Run flutter test next.")


if __name__ == "__main__":
    main()
