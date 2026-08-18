#!/usr/bin/env python3
"""Build and validate a pronunciation dictionary for Qulex.

WHY THIS EXISTS
---------------
The first dictionary shipped 15,226 headwords and silently destroyed audio.
Measured against the live tts function, same voice, same text:

    "fund"       with dictionary -> 0.31s, 0% speech energy   (silent)
                 without         -> 0.91s, 50% speech
    "endowment"  with dictionary -> 0.37s, 14% speech         (near-silent)
                 without         -> 1.10s, 63% speech

A malformed entry does not raise an error. ElevenLabs accepts it and emits
nothing for that word, so definitions lost interior words and single words went
silent. Nothing stood between "phonemes were generated" and "learners heard it".

This tool closes that gap. Every entry is proved by synthesis before it ships:
the word is spoken with the candidate phonemes and again unaided, and an entry
that produces materially less audio than the word does on its own is rejected.

WHY BYTE SIZE IS THE MEASURE
----------------------------
ElevenLabs returns constant-bitrate MP3, so bytes are proportional to duration
within a model. A broken entry comes back dramatically shorter. That means no
audio decoding, no ffmpeg, no extra dependencies — just a length comparison.

PHASES
------
  generate   headwords -> ARPAbet candidates      (no API calls, free)
  validate   candidates -> proved / rejected      (2 API calls per word)
  export     proved -> .pls file to upload        (no API calls, free)

Validation is resumable and ordered by word frequency, so the words learners
actually meet are proved first and you can stop whenever you like — everything
proved so far is usable.

USAGE
-----
    pip install g2p-en requests
    python tools/build_pronunciation_dict.py generate
    set ELEVENLABS_API_KEY=sk_...
    python tools/build_pronunciation_dict.py validate --limit 500
    python tools/build_pronunciation_dict.py export

Then upload the .pls in the ElevenLabs dashboard, and set on the Edge Function:
    USE_PRONUNCIATION_DICT=true
    PRONUNCIATION_DICT_ID=...
    PRONUNCIATION_DICT_VERSION=...
"""

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
WORDS = ROOT / "assets" / "words.json"
OUT = ROOT / "tools" / "pronunciation"
CANDIDATES = OUT / "candidates.json"
STATE = OUT / "validation_state.json"
REJECTED = OUT / "rejected.csv"
PLS = OUT / "qulex_pronunciation.pls"

VOICE_ID = "XoUkt2bf6DlvSzRmvA8X"
MODEL = "eleven_flash_v2"  # the only model in play that honours the dictionary
API = f"https://api.elevenlabs.io/v1/text-to-speech/{VOICE_ID}"

# An entry must produce at least this fraction of the audio the word generates
# unaided. "fund" scored 0.34 of its baseline; a correct entry lands near 1.0.
PASS_RATIO = 0.75
# Below this, a response contains no speech at all whatever the ratio says.
MIN_BYTES = 2048

ARPABET = set("AA AE AH AO AW AY B CH D DH EH ER EY F G HH IH IY JH K L M N NG OW OY "
              "P R S SH T TH UH UW V W Y Z ZH".split())


# ---------------------------------------------------------------------------
# generate
# ---------------------------------------------------------------------------

def load_headwords():
    """English headwords, most frequent first, so validation front-loads value."""
    words = json.loads(WORDS.read_text(encoding="utf-8"))
    seen, out = set(), []
    for w in sorted(words, key=lambda x: x.get("freqRank", 10**9)):
        t = w["word"].strip()
        if not t or t.lower() in seen:
            continue
        seen.add(t.lower())
        out.append(t)
    return out


def valid_arpabet(ph: str) -> bool:
    """Reject anything that is not bare ARPAbet with optional stress digits.

    This is the check the original pipeline lacked. espeak-ng IPA carries stress
    marks, length marks and tie bars that look plausible and are not accepted.
    """
    if not ph or not ph.strip():
        return False
    for tok in ph.split():
        base = tok.rstrip("012")
        if base not in ARPABET:
            return False
    return True


def cmd_generate(args):
    try:
        from g2p_en import G2p
    except ImportError:
        sys.exit("pip install g2p-en  (it carries CMUdict and a neural fallback "
                 "for out-of-vocabulary words, so the whole dictionary comes "
                 "from one lineage in one alphabet)")

    OUT.mkdir(parents=True, exist_ok=True)
    heads = load_headwords()
    g2p = G2p()
    cands, skipped = {}, []

    for i, word in enumerate(heads, 1):
        if not re.fullmatch(r"[A-Za-z][A-Za-z'\- ]*", word):
            skipped.append((word, "non-latin or unusual characters"))
            continue
        try:
            phones = [p for p in g2p(word) if p.strip() and p != " "]
            ph = " ".join(phones)
        except Exception as e:  # noqa: BLE001 - a bad word must not kill the run
            skipped.append((word, f"g2p failed: {e}"))
            continue
        if not valid_arpabet(ph):
            skipped.append((word, f"not clean ARPAbet: {ph!r}"))
            continue
        cands[word] = ph
        if i % 500 == 0:
            print(f"  {i}/{len(heads)}…", flush=True)

    CANDIDATES.write_text(json.dumps(cands, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"\ncandidates : {len(cands)}")
    print(f"skipped    : {len(skipped)}")
    if skipped:
        p = OUT / "generate_skipped.csv"
        p.write_text("word,reason\n" + "\n".join(f'"{w}","{r}"' for w, r in skipped),
                     encoding="utf-8")
        print(f"             -> {p}")
    print(f"written    : {CANDIDATES}")
    print("\nNext: set ELEVENLABS_API_KEY, then `validate`.")


# ---------------------------------------------------------------------------
# validate
# ---------------------------------------------------------------------------

def synth(session, key, text):
    """Return the byte length of the synthesised clip, or None on failure."""
    for attempt in range(4):
        r = session.post(
            API,
            headers={"xi-api-key": key, "Content-Type": "application/json",
                     "Accept": "audio/mpeg"},
            json={"text": text, "model_id": MODEL,
                  "voice_settings": {"stability": 0.75, "similarity_boost": 0.75}},
            timeout=60,
        )
        if r.status_code == 200:
            return len(r.content)
        if r.status_code in (429, 500, 502, 503):
            time.sleep(2 ** attempt)
            continue
        print(f"    HTTP {r.status_code}: {r.text[:160]}")
        return None
    return None


def cmd_validate(args):
    try:
        import requests
    except ImportError:
        sys.exit("pip install requests")

    key = os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        sys.exit("Set ELEVENLABS_API_KEY first.")
    if not CANDIDATES.exists():
        sys.exit("Run `generate` first.")

    cands = json.loads(CANDIDATES.read_text(encoding="utf-8"))
    state = json.loads(STATE.read_text(encoding="utf-8")) if STATE.exists() else {}
    todo = [w for w in cands if w not in state][: args.limit] if args.limit else \
           [w for w in cands if w not in state]

    if not todo:
        print("Nothing left to validate.")
        return

    chars = sum(len(w) * 2 + 60 for w in todo)
    print(f"to validate : {len(todo)} words ({len(state)} already done)")
    print(f"API calls   : {len(todo) * 2}")
    print(f"~characters : {chars:,}  <- this is what ElevenLabs bills")
    if not args.yes and input("Proceed? (y/N) ").strip().lower() not in ("y", "yes"):
        return

    session = requests.Session()
    OUT.mkdir(parents=True, exist_ok=True)
    passed = failed = errors = 0

    for i, word in enumerate(todo, 1):
        ph = cands[word]
        tagged = f'<phoneme alphabet="cmu-arpabet" ph="{ph}">{word}</phoneme>'
        # Baseline first: what the model does with the bare word.
        base = synth(session, key, word)
        got = synth(session, key, tagged) if base else None

        if not base or not got:
            state[word] = {"ok": False, "reason": "api error"}
            errors += 1
        elif got < MIN_BYTES:
            state[word] = {"ok": False, "reason": f"no audio ({got}B)", "base": base, "got": got}
            failed += 1
        elif got / base < PASS_RATIO:
            state[word] = {"ok": False, "reason": f"short ({got/base:.2f} of baseline)",
                           "base": base, "got": got}
            failed += 1
        else:
            state[word] = {"ok": True, "ratio": round(got / base, 2)}
            passed += 1

        if i % 25 == 0 or i == len(todo):
            STATE.write_text(json.dumps(state, indent=1), encoding="utf-8")
            print(f"  {i}/{len(todo)}  pass {passed}  reject {failed}  err {errors}", flush=True)

    STATE.write_text(json.dumps(state, indent=1), encoding="utf-8")
    bad = [(w, v) for w, v in state.items() if not v.get("ok")]
    REJECTED.write_text(
        "word,phonemes,reason\n" +
        "\n".join(f'"{w}","{cands.get(w,"")}","{v.get("reason","")}"' for w, v in bad),
        encoding="utf-8")
    print(f"\npassed {passed}   rejected {failed}   errors {errors}")
    print(f"rejections -> {REJECTED}")


# ---------------------------------------------------------------------------
# export
# ---------------------------------------------------------------------------

def cmd_export(args):
    if not (CANDIDATES.exists() and STATE.exists()):
        sys.exit("Run `generate` and `validate` first.")
    cands = json.loads(CANDIDATES.read_text(encoding="utf-8"))
    state = json.loads(STATE.read_text(encoding="utf-8"))
    good = {w: cands[w] for w, v in state.items() if v.get("ok") and w in cands}

    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<lexicon version="1.0" xmlns="http://www.w3.org/2005/01/pronunciation-lexicon"',
             '         alphabet="cmu-arpabet" xml:lang="en-US">']
    for w in sorted(good):
        lines.append(f"  <lexeme><grapheme>{escape(w)}</grapheme>"
                     f"<phoneme>{escape(good[w])}</phoneme></lexeme>")
    lines.append("</lexicon>")
    PLS.write_text("\n".join(lines), encoding="utf-8")

    print(f"proved entries : {len(good)}")
    print(f"written        : {PLS}")
    print("\nUpload it in the ElevenLabs dashboard, then set on the Edge Function:")
    print("  USE_PRONUNCIATION_DICT=true")
    print("  PRONUNCIATION_DICT_ID=<id>")
    print("  PRONUNCIATION_DICT_VERSION=<version>")
    print("\nEvery entry in this file has been spoken and measured. Entries that")
    print("produced no audio are in rejected.csv and are NOT included.")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("generate")
    v = sub.add_parser("validate")
    v.add_argument("--limit", type=int, default=0, help="validate at most N more words")
    v.add_argument("--yes", action="store_true", help="skip the cost confirmation")
    sub.add_parser("export")
    a = ap.parse_args()
    {"generate": cmd_generate, "validate": cmd_validate, "export": cmd_export}[a.cmd](a)
