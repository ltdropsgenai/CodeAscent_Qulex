#!/usr/bin/env python3
"""Merge mined citations into the bundled catalogue.

    python tools/apply_attested_examples.py

Separate from the miner because assets/words.json is 38MB and cannot be moved
between machines, so this has to reproduce the edit locally rather than
receive it. It refuses to write unless the starting file is the one this was
built against and the result hashes to the value already committed in
lib/data/catalogue_ota.dart — if it prints that hash, your catalogue is
byte-identical to the one the tests were written for.

Adds gloss.en.attested = {text, source, attribution} to every headword the
miner found. Touches nothing else: not example, not example2, not any
non-English gloss. See the miner's header for why the citation is never
translated.
"""
import collections
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORDS = ROOT / "assets" / "words.json"
MINED = ROOT / "tools" / "attested_examples.json"

BEFORE = "7350b3aaf31bf4058c1d0de11d17e1639dee5438420b84d85f34581bcc6e4052"
EXPECT = "69a22fb65d4563a63932054d04837584b4a73bfe3579511b5f1fc7588178c464"
LICENCE = "CC BY 2.0 FR · tatoeba.org/sentences/{sid}"


def attests(head: str, text: str) -> bool:
    """Does this sentence actually contain the word it claims to cite?

    The miner's inflection rules are generous on purpose, and generosity
    produces the occasional coincidence: "froe" was cited by "after a lot of
    toing and froing", which is the word *fro*. One in 9,502, and it would
    have shipped. Words of four letters or fewer must match exactly; longer
    ones may lose a final letter to inflection.
    """
    head, text = head.lower(), text.lower()
    stem = head[:-1] if len(head) > 4 else head
    return stem in text


def main():
    if not WORDS.exists():
        sys.exit(f"run this from the repo root — cannot find {WORDS}")
    if not MINED.exists():
        sys.exit(f"cannot find {MINED}. Run: python tools/mine_attested_examples.py mine")

    raw = WORDS.read_bytes()
    have = hashlib.sha256(raw).hexdigest()
    if have == EXPECT:
        sys.exit("already applied — the asset already hashes to the committed value.")
    if have != BEFORE:
        sys.exit(f"unexpected starting file.\n  expected {BEFORE}\n  found    {have}\n"
                 "Nothing written.")

    mined = json.loads(MINED.read_text(encoding="utf-8"))
    words = json.loads(raw, object_pairs_hook=collections.OrderedDict)

    added = rejected = 0
    for w in words:
        rec = mined.get(w["word"].lower())
        if not rec:
            continue
        if not attests(w["word"], rec["text"]):
            rejected += 1
            continue
        w["gloss"]["en"]["attested"] = collections.OrderedDict([
            ("text", rec["text"]),
            ("source", "tatoeba"),
            ("attribution", LICENCE.format(sid=rec["sid"])),
        ])
        added += 1

    out = json.dumps(words, separators=(", ", ": "), ensure_ascii=False).encode("utf-8")
    sha = hashlib.sha256(out).hexdigest()
    if sha != EXPECT:
        sys.exit(f"refusing to write — hash mismatch.\n"
                 f"  expected {EXPECT}\n  produced {sha}")

    WORDS.write_bytes(out)
    print(f"citations added   : {added:,}")
    print(f"rejected as false : {rejected}")
    print(f"bytes  {len(raw):,} -> {len(out):,}")
    print(f"sha256 {sha}")
    print("matches kBundledCatalogueSha256. Run flutter test next.")


if __name__ == "__main__":
    main()
