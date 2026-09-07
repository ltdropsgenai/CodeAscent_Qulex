#!/usr/bin/env python3
"""Respell seventeen French loanwords, each one heard right before it was written.

    python tools/fix_french_says.py

WHERE THESE CAME FROM

On 7 Sep a learner reported `glissade` spoken as "gli-say-di" in a live game.
The extra syllable was the diagnosis: the engine was voicing the terminal
silent `e`. A filter for French orthography found 182 catalogue words in the
same shape, every one of them absent from CMUdict, none ever surveyed.

The fix was NOT found by hunting for which of the 182 are broken. It was found
by looking up what each word should sound like, writing a respelling for it,
and listening to the respelling. A correct respelling is harmless on a word
that was already correct - it just reproduces the sound - so the expensive
half of the old procedure bought nothing.

The accepted pronunciations are recorded in tools/pronunciation/reference.json.
Read its header before adding to this list: THE TARGET IS ACCEPTED ENGLISH, NOT
FRENCH. `persillade` below ends in -AYD on purpose. `chamois` is `shammy`.
Grading these against French would have marked both correct clips wrong and
replaced them with something no English speaker says.

WHAT THE LISTENING SETTLED

    glissade    glissahd     over glissayd, glissod, glissaad, and glisahd
                             (glisahd also passed; glissahd keeps the double
                             s of the headword, which is the only reason it
                             won - both were heard right)
    sillage     seeyahzh     over seeyazh and seeyahj
    frottage    frohtahzh    over frohtazh

English has no settled spelling for the /Z/ in `vision`, so those two were
given three shots and two shots. `-ahzh` took both. The long `ah` is doing the
work: `-azh` lost twice.

Eight more were tried and failed - tapenade, panade, chocolatier, cuirassier,
chalumeau, brevet, grimpeur, repechage. They are NOT in this file. A word with
no `say` is spoken as spelled, which is where it already was; a word with a
wrong `say` is spoken wrong forever, because `say` beats every other rule in
the engine and nothing downstream questions it.
"""
import collections
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORDS = ROOT / "assets" / "words.json"

BEFORE = "963235002613058060e9d52180b471337d8bc760809f3316e74e24cbb1fa6114"
EXPECT = "0867541c212ba4c70aa020678d2a58dcff29ad787a763681871394aa446c8ee7"

SAY = {
    "glissade":   "glissahd",
    "aubade":     "ohbahd",
    "pochade":    "pohshahd",
    "couvade":    "koovahd",
    "bigarade":   "beeguhrahd",
    "persillade": "persillayd",
    "praline":    "prahleen",
    "mousseline": "moosuhleen",
    "quenelle":   "kuhnell",
    "chandelle":  "shandell",
    "moire":      "mwahr",
    "escritoire": "eskritwahr",
    "terroir":    "tehrwahr",
    "auteur":     "ohtur",
    "chamois":    "shammy",
    "frottage":   "frohtahzh",
    "sillage":    "seeyahzh",
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
                 "Nothing written.")

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
        print(f"  {k:<12} say -> {SAY[k]}")
    print(f"\n{len(done)} respellings applied")
    print(f"sha256 {sha}")
    print("Update kBundledCatalogueSha256 and bump the generation, then flutter test.")


if __name__ == "__main__":
    main()
