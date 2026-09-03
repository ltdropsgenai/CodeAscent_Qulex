#!/usr/bin/env python3
"""Respell the seven -ite words a listening survey found wrong.

    python tools/fix_ite_says.py     # after tools/fix_mullite_say.py

WHERE THESE CAME FROM

108 catalogue words end in -ite, which has three readings in English: /aIt/
(dynamite), /It/ (granite) and /i:t/ (elite). CMUdict covers 47 of them, so
ElevenLabs has a reference and reads those correctly. It has no entry for the
other 61 — and mullite, reported wrong from a live game, was one of them.

All 60 single-token unknowns were synthesized and judged by ear. Eight were
wrong: 13.3%, against a corrected catalogue baseline near 2%. The filter is
worth roughly seven times the base rate. Predicting WHICH ones inside it would
fail was worth nothing: a recorded prediction of five likely failures scored
1 of 5, and seven of the eight real failures had been predicted to pass.

Each replacement below beat an alternative head to head before being written.

    fomite        fomight        over foh-might
    saprolite     saprolight     over sap-ruh-light
    ignimbrite    ignimbright    over ig-nim-bright
    turbidite     turbidight     over tur-buh-dight
    cristobalite  cristobalight  over kris-toh-buh-light
    kimarite      kimaritay      over kee-mah-ree-tay
    tsavorite     sav-uh-right   over tsavoright AND tsah-vuh-right

Note the last one. Both attempts to keep the initial /ts/ failed, so the
winner concedes it. A respelling cannot make the voice produce a phoneme it
will not produce; what it can do is land on the sound a learner should hear.

Dictionary references: fomite, saprolite, ignimbrite and turbidite from
Merriam-Webster; cristobalite /krI'stoUb@%laIt/ from Dictionary.com; kimarite
is Japanese and takes the same -te as kumite, which Dictionary.com gives as
/'ku:mI%teI/; tsavorite settled by ear against conflicting trade sources.
"""
import collections
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORDS = ROOT / "assets" / "words.json"

BEFORE = "ff9387a8cf174fcdf0287cfe39723305f25d8138d7f5bc04ff72895274ed00c8"
EXPECT = "963235002613058060e9d52180b471337d8bc760809f3316e74e24cbb1fa6114"

SAY = {
    "fomite": "fomight",
    "saprolite": "saprolight",
    "ignimbrite": "ignimbright",
    "turbidite": "turbidight",
    "cristobalite": "cristobalight",
    "tsavorite": "sav-uh-right",
    "kimarite": "kimaritay",
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
                 "Run tools/fix_mullite_say.py first. Nothing written.")

    words = json.loads(raw, object_pairs_hook=collections.OrderedDict)
    pos = list(next(w for w in words if w.get("say")).keys()).index("say")

    done = []
    for i, w in enumerate(words):
        key = w["word"].lower()
        if key not in SAY:
            continue
        if w.get("say"):
            sys.exit(f"{key} already carries say={w['say']!r}")
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
    print(f"\n{len(done)} respellings applied")
    print(f"sha256 {sha}")
    print("matches kBundledCatalogueSha256. Run flutter test next.")


if __name__ == "__main__":
    main()
