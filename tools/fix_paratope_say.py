#!/usr/bin/env python3
"""Correct the paratope respelling. Run AFTER apply_attested_examples.py.

    python tools/apply_attested_examples.py     # first
    python tools/fix_paratope_say.py            # then this

Build 44 ships `paratope` as "parra-tope" and it is still heard as PAR-uh-TOP.
"tope" has two readings and the model picks the wrong one. "taupe" has one.

Verified before writing, not after: three candidates were synthesized through
the live tts function and judged by ear — parra-taupe right, parruh-taupe
wrong, par-uh-taupe wrong. So only the final syllable was ever broken; the
"parra-" that shipped was correct all along.

The same listen tested sarcomere and left it alone. "sarcomeer" beat both
"sar-kuh-meer" and "sar-kuh-mere", so it is not touched here — an invented
spelling that already sounds right does not need to be made more principled.

Separate from apply_attested_examples.py because it is a different kind of
change, and because the two hashes chain: this expects the catalogue the other
one produces.
"""
import collections
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORDS = ROOT / "assets" / "words.json"

BEFORE = "69a22fb65d4563a63932054d04837584b4a73bfe3579511b5f1fc7588178c464"
EXPECT = "070b1b19a23af555db9ed11c8d35007d5c3276be0f73ce29bdb6668d24f2bd22"
OLD, NEW = "parra-tope", "parra-taupe"


def main():
    if not WORDS.exists():
        sys.exit(f"run this from the repo root — cannot find {WORDS}")
    raw = WORDS.read_bytes()
    have = hashlib.sha256(raw).hexdigest()
    if have == EXPECT:
        sys.exit("already applied.")
    if have != BEFORE:
        sys.exit(
            f"unexpected starting file.\n  expected {BEFORE}\n  found    {have}\n"
            "Run tools/apply_attested_examples.py first. Nothing written."
        )

    words = json.loads(raw, object_pairs_hook=collections.OrderedDict)
    hits = 0
    for w in words:
        if w["word"].lower() == "paratope":
            if w.get("say") != OLD:
                sys.exit(f"paratope carries say={w.get('say')!r}, expected {OLD!r}")
            w["say"] = NEW
            hits += 1
    if hits != 1:
        sys.exit(f"expected exactly one paratope entry, found {hits}")

    out = json.dumps(words, separators=(", ", ": "), ensure_ascii=False).encode("utf-8")
    sha = hashlib.sha256(out).hexdigest()
    if sha != EXPECT:
        sys.exit(f"refusing to write — hash mismatch.\n  expected {EXPECT}\n  produced {sha}")

    WORDS.write_bytes(out)
    print(f"paratope: {OLD} -> {NEW}")
    print(f"sha256 {sha}")
    print("matches kBundledCatalogueSha256. Run flutter test next.")


if __name__ == "__main__":
    main()
