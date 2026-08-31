#!/usr/bin/env python3
"""Mine real published sentences for catalogue headwords.

    python tools/mine_attested_examples.py mine     # ~5 min, ~600MB scratch
    python tools/apply_attested_examples.py         # merge into the catalogue

WHY THIS EXISTS

Every example sentence in the catalogue was generated. That is fine for
teaching — they are short, they use the target sense, and they exist for all
16,808 words in five languages, which no corpus could give us. But it is the
one row on the capability board where a competitor genuinely leads on
substance: Vocabulary.com shows the word in text somebody actually published,
and "seeing the word actually used" is a different claim from "seeing a
sentence written to demonstrate it".

This mines that second thing from Tatoeba (CC BY 2.0 FR): 2,035,404 English
sentences, contributed and corrected by humans, contemporary register.

WHAT IT DOES NOT DO

It does not replace the generated examples. gloss.{lang}.example and .example2
are a PARALLEL TRANSLATION SET — the Spanish example is the Spanish rendering
of the English one — and the app shows the pair together. Swapping one side
for an untranslated corpus sentence puts a mismatched line under the English,
which is exactly the fault this app shipped in August and had to fix. So the
citation lands in its own field, English only, and is never translated.

COVERAGE, HONESTLY

9,501 of 16,808 headwords. By difficulty: 96% of easy, 74% of medium, 31% of
hard. Tatoeba is conversational, so it reaches everyday vocabulary and misses
the technical tail — there is no sentence in it containing "paratope". Words
with no attestation keep their generated examples and show no citation, which
is the correct outcome: a citation nobody wrote is not something to invent.

LICENCE

CC BY 2.0 FR requires attribution. Every mined sentence carries its Tatoeba
sentence id and licence in the same object as the text, and a test fails the
build if the two are ever separated.
"""
import argparse
import bz2
import collections
import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRATCH = ROOT / "tools" / "pronunciation" / "_corpus"
OUT = ROOT / "tools" / "attested_examples.json"
WORDS = ROOT / "assets" / "words.json"
EXPORT = "https://downloads.tatoeba.org/exports/per_language/eng/eng_sentences.tsv.bz2"

LONG = re.compile(r"\b\w{14,}\b")
TOKEN = re.compile(r"[a-z][a-z'-]*")


def forms(w: str) -> set:
    """Surface forms that count as an attestation of the headword.

    Deliberately generous, then checked: `apply` re-verifies that the chosen
    sentence contains the word, because a generous rule produces occasional
    nonsense. It found exactly one in 9,502 — "froe" attested by "a lot of
    toing and froing", which is the word *fro*.
    """
    f = {w}
    if not w.endswith("s"):
        f.add(w + "s")
    if w.endswith(("s", "x", "z", "ch", "sh")):
        f.add(w + "es")
    if w.endswith("y") and len(w) > 2 and w[-2] not in "aeiou":
        f.add(w[:-1] + "ies")
    if w.endswith("e"):
        f |= {w + "d", w[:-1] + "ing"}
    else:
        f |= {w + "ed", w + "ing"}
    return f


def score(text: str, head: str) -> float:
    """Higher is better. A bad citation is worse than a good generated example."""
    words = text.split()
    n = len(words)
    if n < 6 or n > 18:
        return -1                      # too terse to show context, or a wall
    if not text.rstrip().endswith((".", "!", "?")):
        return -1                      # a fragment
    if text.count('"') > 2 or "http" in text:
        return -1
    if sum(1 for w in words if w.isupper() and len(w) > 1) > 1:
        return -1
    s = 3.0 if 8 <= n <= 14 else 1.0
    low = [w.lower() for w in words]
    idx = next((i for i, w in enumerate(low) if head in w), 0)
    s += 1.5 if 0 < idx < n - 1 else 0.0      # used mid-sentence, not announced
    s -= 1.0 * len(LONG.findall(text))        # other hard words hurt readability
    s += 0.5 if text.rstrip().endswith(".") else 0.0
    s -= 0.4 if re.search(r"\b(Tom|Mary)\b", text) else 0.0  # Tatoeba's stock cast
    return s


def cmd_mine(args):
    SCRATCH.mkdir(parents=True, exist_ok=True)
    local = SCRATCH / "eng_sentences.tsv.bz2"
    if not local.exists() or args.refresh:
        print(f"downloading {EXPORT} …")
        urllib.request.urlretrieve(EXPORT, local)
    print(f"corpus: {local.stat().st_size/1e6:.0f} MB")

    heads = {}
    for x in json.loads(WORDS.read_text(encoding="utf-8")):
        heads[x["word"].lower()] = x
    form2head = {}
    for h in heads:
        for f in forms(h):
            form2head.setdefault(f, h)
    print(f"{len(heads):,} headwords, {len(form2head):,} surface forms")

    hits = collections.defaultdict(list)
    n = 0
    with bz2.open(local, "rt", encoding="utf-8") as fh:
        for line in fh:
            n += 1
            p = line.rstrip("\n").split("\t")
            if len(p) < 3:
                continue
            sid, text = p[0], p[2]
            seen = set()
            for m in TOKEN.findall(text.lower()):
                h = form2head.get(m)
                if h and h not in seen:
                    seen.add(h)
                    if len(hits[h]) < 40:
                        hits[h].append((sid, text))
    print(f"scanned {n:,} sentences; {len(hits):,} headwords have a candidate")

    out = {}
    for head, cands in hits.items():
        best = None
        for sid, text in cands:
            sc = score(text, head)
            if sc >= 0 and (best is None or sc > best[0]):
                best = (sc, sid, text)
        if best:
            out[head] = {"text": best[2], "sid": int(best[1])}
    OUT.write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":"),
                              sort_keys=True), encoding="utf-8")
    print(f"\n{len(out):,} citations survived the quality filter")
    print(f"written {OUT.relative_to(ROOT)}  ({OUT.stat().st_size/1e6:.2f} MB)")

    by = collections.Counter()
    tot = collections.Counter()
    for w, x in heads.items():
        tot[x.get("difficulty", "?")] += 1
        if w in out:
            by[x.get("difficulty", "?")] += 1
    print("\ncoverage by difficulty:")
    for d in ("easy", "medium", "hard"):
        if tot[d]:
            print(f"  {d:<7}: {by[d]:>6}/{tot[d]:>6} = {by[d]/tot[d]*100:5.1f}%")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("mine", help="download the corpus and write attested_examples.json")
    m.add_argument("--refresh", action="store_true",
                   help="re-download the corpus even if it is already cached")
    m.set_defaults(func=cmd_mine)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
