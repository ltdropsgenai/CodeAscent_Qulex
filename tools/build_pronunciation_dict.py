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

This tool closes that gap. Every entry is proved by synthesis before it ships.

WHY LENGTH ALONE IS NOT ENOUGH
------------------------------
The first version of this validator compared the byte length of the tagged clip
against the bare word and rejected anything materially shorter. `selftest`
proved that gate blind:

    fund  "F AH1 N D"   ratio 1.00  accept   correct
    fund  "ˈfʌnd"        ratio 0.67  REJECT   espeak IPA - caught
    fund  "Q Q Q Q"     ratio 1.33  accept   NONSENSE - PASSED

A length test only detects entries that make audio *shorter*. It is structurally
incapable of detecting an entry that produces the wrong sound at roughly the
right duration - which includes the worst case for a teaching app: a well-formed
ARPAbet string for the wrong word. "199/200 passed" under that gate meant
"199 produced about the right amount of audio", not "199 were correct".

So the gate now has three stages, and only the third is about correctness:

  1. format       valid_arpabet()   free, at generate time. Rejects IPA and
                                    symbols outside the ARPAbet set.
  2. length       byte ratio        cheap. Rejects silence and truncation
                                    before spending an STT call.
  3. recognition  speech-to-text    the actual oracle. The tagged clip is
                                    transcribed and the transcript must match
                                    the headword - phonetically, so homophone
                                    spellings ("flour" heard as "flower") are
                                    not false rejections.

Stage 3 is what makes a pass mean something. If the phonemes say "found" and
the headword is "fund", the transcript says "found" and the entry is rejected,
however healthy its duration looked.

Known limits, stated plainly:
  - Scribe is not perfect. Some rejections will be the recogniser's fault, not
    the entry's. They land in rejected.csv with what was heard, so they can be
    read rather than guessed at.
  - Stress placement is not verified. REcord vs reCORD both transcribe as
    "record". Heteronym stress remains outside what this proves.
  - A pass means "spoken aloud, and heard back as this word". It does not mean
    "matches a dictionary's preferred pronunciation".

WHY BYTE SIZE IS THE MEASURE (stage 2)
--------------------------------------
ElevenLabs returns constant-bitrate MP3, so bytes are proportional to duration
within a model. No audio decoding, no ffmpeg, no extra dependencies.

WHAT IS AND IS NOT IN THE DICTIONARY
------------------------------------
Only headwords CMUdict can vouch for. The rank-12,000 sample proved that where
CMUdict runs out, g2p-en's neural fallback does not degrade gracefully - it
fabricates:

    chelation      CH EH1 L AH0 T AH0 N        heard back as "gelatin"
    livershot      L IH1 V ER0 S T UW2         heard back as "liver stew"
    barycenter     B EH1 R IY0 S T EH0 N ER0   heard back as "Barry Stenner"
    corticospinal  ... S IH1 P AH0 N AH0 L     heard back as "Corticocipanol"

Every one of those had a healthy duration and would have shipped under a
length-only gate. That is the same stretch of vocabulary the original espeak-IPA
entries came from, and the same failure wearing a different mask.

So ~5,664 headwords are DEFERRED, listed in deferred_no_reference.csv with their
untrusted phonemes. They are not in the dictionary and they are not proved. They
fall back to ElevenLabs' own reading, which every baseline measurement in this
file shows is fine. Covering them properly needs a real reference (Wiktionary
IPA, or hand-curation for the ones learners actually meet) - that is open work,
not a closed question. Run `validate --scope uncovered` when a better source
exists.

PHASES
------
  generate   headwords -> ARPAbet candidates      (no API calls, free)
  validate   candidates -> proved / rejected      (2 TTS + 1 STT per word)
  export     proved -> .pls file to upload        (no API calls, free)

Validation is resumable and ordered by word frequency, so the words learners
actually meet are proved first and you can stop whenever you like - everything
proved so far is usable.

USAGE
-----
    pip install g2p-en requests
    python tools/build_pronunciation_dict.py generate
    python tools/build_pronunciation_dict.py offline     # free, no key
    $env:ELEVENLABS_API_KEY="sk_..."          # PowerShell
    python tools/build_pronunciation_dict.py selftest    # ~14 API calls
    python tools/build_pronunciation_dict.py validate --limit 500
    python tools/build_pronunciation_dict.py export

Run `selftest` first and every time this file changes. It is the only thing
standing between "the gate passed everything" and "the entries are correct".

Then upload the .pls in the ElevenLabs dashboard, and set on the Edge Function:
    USE_PRONUNCIATION_DICT=true
    PRONUNCIATION_DICT_ID=...
    PRONUNCIATION_DICT_VERSION=...
"""

import argparse
import json
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
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
DEFERRED = OUT / "deferred_no_reference.csv"

VOICE_ID = "XoUkt2bf6DlvSzRmvA8X"
MODEL = "eleven_flash_v2"  # the only model in play that honours the dictionary
API = f"https://api.elevenlabs.io/v1/text-to-speech/{VOICE_ID}"
STT_API = "https://api.elevenlabs.io/v1/speech-to-text"
STT_MODEL = "scribe_v1"

# Bump this whenever the gate changes. Entries proved by an older, weaker gate
# are re-validated rather than trusted: the 400 words that passed under the
# length-only oracle were never checked for correctness at all.
ORACLE_VERSION = 2

# Stage 2. An entry must produce at least this fraction of the audio the word
# generates unaided. "fund" scored 0.34 of its baseline with the broken entry.
PASS_RATIO = 0.75
# Below this, a response contains no speech at all whatever the ratio says.
MIN_BYTES = 2048
# Hard ceiling. Above this the clip is not the word plus a little breathing
# room, it is the word plus other speech. Measured on the full run:
#   reveal  3.57  heard "Rise may as to mean reveal"
#   lapel   3.37  heard "E noninim lapel"
#   ravine  3.08  heard "What a kind ravine"
# All three were ACCEPTED by recognition, because the transcript really does
# contain the headword - it just contains a sentence around it too. A learner
# tapping "reveal" would hear a stray phrase. Recognition alone cannot catch
# this; length alone could not catch the wrong-word case. Both bounds are load
# bearing, for different failures.
MAX_RATIO = 1.5
# Advisory only. Correct entries land near 1.0; "Q Q Q Q" came back at 1.33
# because nonsense takes longer to read out than the word does. Stage 3 is what
# actually rejects it - this threshold only flags the entry for a human read.
LONG_RATIO = 1.25

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


def ensure_nltk():
    """g2p-en leans on NLTK's POS tagger, and NLTK renamed that resource.

    Newer NLTK wants `averaged_perceptron_tagger_eng`; g2p-en's own bootstrap
    still asks for the old `averaged_perceptron_tagger`. When the new name is
    missing every single call raises, which looks exactly like a data problem
    and is not one. Fetch both names and move on.
    """
    try:
        import nltk
    except ImportError:
        sys.exit("pip install nltk  (g2p-en depends on it)")
    for res in ("averaged_perceptron_tagger_eng", "averaged_perceptron_tagger", "cmudict"):
        try:
            nltk.download(res, quiet=True)
        except Exception:  # noqa: BLE001 - one missing alias is not fatal
            pass


_G2P = None
_CMU = None


def get_g2p():
    """Shared G2p instance - loading it costs a few seconds, so do it once."""
    global _G2P
    if _G2P is None:
        try:
            from g2p_en import G2p
        except ImportError:
            sys.exit("pip install g2p-en  (needed to turn headwords, and what "
                     "the recogniser heard, into ARPAbet)")
        ensure_nltk()
        _G2P = G2p()
    return _G2P


def get_cmu():
    """CMUdict, including its alternate pronunciations.

    The transcript side of the gate compares what Scribe heard against what we
    asked the model to say. CMUdict is the right lookup for that: transcripts
    are ordinary English words, and CMUdict lists every accepted pronunciation,
    so "flour" and "flower" resolve to the same phones instead of looking like
    a mismatch. g2p-en only fills in words CMUdict has never heard of.
    """
    global _CMU
    if _CMU is None:
        ensure_nltk()
        try:
            from nltk.corpus import cmudict
            _CMU = cmudict.dict()
        except Exception as e:  # noqa: BLE001
            sys.exit(f"CMUdict unavailable ({e}). The recognition gate cannot "
                     f"run without it, and running without it would mean "
                     f"passing entries nobody checked. Fix the NLTK data first.")
    return _CMU


def cmd_generate(args):
    try:
        from g2p_en import G2p  # noqa: F401 - imported for the error message
    except ImportError:
        sys.exit("pip install g2p-en  (it carries CMUdict and a neural fallback "
                 "for out-of-vocabulary words, so the whole dictionary comes "
                 "from one lineage in one alphabet)")

    OUT.mkdir(parents=True, exist_ok=True)
    heads = load_headwords()
    g2p = get_g2p()
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
            # A broken environment fails on every word. Say so on the first
            # handful rather than producing a 16,000-line report that reads
            # like a data problem.
            if len(skipped) >= 5 and not cands:
                print("\ng2p failed on the first 5 words - this is the setup, "
                      "not your data. First error:\n")
                print(str(e)[:600])
                sys.exit(1)
            continue
        if not valid_arpabet(ph):
            skipped.append((word, f"not clean ARPAbet: {ph!r}"))
            continue
        cands[word] = ph
        if i % 500 == 0:
            print(f"  {i}/{len(heads)}...", flush=True)

    CANDIDATES.write_text(json.dumps(cands, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"\ncandidates : {len(cands)}")
    print(f"skipped    : {len(skipped)}")
    if skipped:
        p = OUT / "generate_skipped.csv"
        p.write_text("word,reason\n" + "\n".join(f'"{w}","{r}"' for w, r in skipped),
                     encoding="utf-8")
        print(f"             -> {p}")
    print(f"written    : {CANDIDATES}")
    print("\nNext: set ELEVENLABS_API_KEY, run `selftest`, then `validate`.")


# ---------------------------------------------------------------------------
# the gate
# ---------------------------------------------------------------------------

def synth(session, key, text):
    """Return the synthesised MP3 bytes, or None on failure."""
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
            return r.content
        if r.status_code in (429, 500, 502, 503):
            time.sleep(2 ** attempt)
            continue
        print(f"    TTS HTTP {r.status_code}: {r.text[:160]}")
        return None
    return None


def transcribe(session, key, audio):
    """Return what Scribe heard in the clip, or None on failure.

    This is stage 3 - the only stage that tests whether the audio says the
    right word rather than merely the right amount of something.
    """
    for attempt in range(4):
        r = session.post(
            STT_API,
            headers={"xi-api-key": key},
            files={"file": ("clip.mp3", audio, "audio/mpeg")},
            data={"model_id": STT_MODEL, "language_code": "eng"},
            timeout=120,
        )
        if r.status_code == 200:
            try:
                return (r.json().get("text") or "").strip()
            except ValueError:
                return None
        if r.status_code in (429, 500, 502, 503):
            time.sleep(2 ** attempt)
            continue
        print(f"    STT HTTP {r.status_code}: {r.text[:160]}")
        return None
    return None


def norm_text(s: str) -> str:
    """Lowercase, drop punctuation, collapse whitespace."""
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9' ]+", " ", (s or "").lower())).strip()


def bare(phones):
    """ARPAbet tokens with stress digits removed.

    Stress is deliberately not compared. Scribe transcribes REcord and reCORD
    identically, so this gate has no way to tell them apart and pretending
    otherwise would be the same false confidence that shipped the last
    dictionary. Heteronym stress stays a known gap, listed in selftest.
    """
    return tuple(t.rstrip("012") for t in phones if str(t).strip())


def phone_sets(text: str, allow_g2p: bool):
    """Every phone sequence `text` could be, as a set of tuples.

    CMUdict alternates are all included, so a word with two accepted readings
    matches if either one is what came back. Returns (set, fully_covered);
    fully_covered is False when a token was not in CMUdict at all.
    """
    cmu, g2p = get_cmu(), None
    variants, covered = [()], True
    for tok in norm_text(text).split():
        entries = cmu.get(tok)
        if not entries:
            covered = False
            if not allow_g2p:
                return set(), False
            g2p = g2p or get_g2p()
            entries = [[p for p in g2p(tok) if str(p).strip() and p != " "]]
        variants = [v + bare(e) for v in variants for e in entries][:64]
    return set(variants), covered


def has_reference(word: str) -> bool:
    """True when CMUdict lists every token of the headword.

    This is the line between an entry the gate can prove and one it can only
    watch render. It is also, empirically, the line between g2p-en reporting
    CMUdict and g2p-en inventing. Measured on the rank-12,000 sample:

        chelation      CH EH1 L AH0 T AH0 N   should be K IY0 L EY1 SH AH0 N
        livershot      L IH1 V ER0 S T UW2    heard as "liver stew"
        barycenter     B EH1 R IY0 S T EH0 N ER0   heard as "Barry Stenner"
        excipient      IH0 K S AY1 P AH0 N T  lost the whole "-ee-ent"

    Those are not near misses, and Scribe was transcribing them correctly.
    Words with no CMUdict entry are deferred rather than shipped: ElevenLabs'
    own unaided reading of them is better than this, which is what every
    baseline measurement in this file has been showing all along.
    """
    cmu = get_cmu()
    return all(cmu.get(t) for t in norm_text(word).split())


def heard_matches(word: str, heard: str):
    """Does the transcript name the headword? Returns (bool, how).

    NOTE THE COMPARISON. The transcript is checked against the HEADWORD, never
    against the candidate phonemes. Comparing it to the candidate is circular
    and useless: ask for "F AW1 N D" on the headword "fund" and the clip really
    does say "found", so a transcript-vs-candidate check calls it a match and
    ships "found" to a learner who asked for "fund". The first draft of this
    function did exactly that, and the offline cases below caught it.

    Spelling equality first, because it is free and unambiguous. Failing that,
    compare phonetically against CMUdict's readings of the headword: Scribe
    writes "flower" for the audio of "flour" and "eight" for "ate". Those are
    the recogniser choosing a spelling, not the entry being wrong, and
    rejecting them would throw away correct lines.

    The phonetic comparison is exact after stress is stripped - no edit-distance
    tolerance. "fund" and "found" differ by one phone, and a gate loose enough
    to forgive one phone is a gate that ships the wrong word. A correct entry
    rejected here lands in rejected.csv with what was heard, where it can be
    read and re-added by hand. That is the cheaper mistake to make.

    Headwords CMUdict has never seen get the spelling check only - there is no
    independent reference for them, and deriving one from g2p-en would just be
    the circular check again wearing a different hat. Those rejections are
    labelled so they can be reviewed rather than guessed at.
    """
    w, h = norm_text(word), norm_text(heard)
    if not h:
        return False, "nothing heard"
    if h == w:
        return True, "exact"
    # Scribe sometimes pads a single word into a short phrase ("a fund").
    if w in h.split() or (" " in w and w in h):
        return True, "contains"
    ref, covered = phone_sets(w, allow_g2p=False)
    if not covered:
        return False, f"heard '{h}' (no independent reference)"
    got, _ = phone_sets(h, allow_g2p=True)
    if ref & got:
        return True, "homophone"
    return False, f"heard '{h}'"


# Transient failures deliberately do NOT carry ORACLE_VERSION. A word is
# "done" only when the gate reached a verdict about it; a 429 storm or a
# dropped socket is not a verdict. Stamping those would quietly exclude them
# from the dictionary forever with nothing to show it happened - the exact
# shape of failure this whole file exists to stop.
def judge(session, key, word, ph):
    """Run all three stages against one candidate. Returns a state dict."""
    tagged = f'<phoneme alphabet="cmu-arpabet" ph="{ph}">{word}</phoneme>'
    base = synth(session, key, word)
    got = synth(session, key, tagged) if base else None
    if not base or not got:
        return {"ok": False, "reason": "api error"}          # unstamped: retry me

    ratio = len(got) / len(base)
    rec = {"v": ORACLE_VERSION, "ratio": round(ratio, 2),
           "base": len(base), "got": len(got)}

    # Stage 2 - silence and truncation, rejected without spending an STT call.
    if len(got) < MIN_BYTES:
        return {**rec, "ok": False, "reason": f"no audio ({len(got)}B)"}
    if ratio < PASS_RATIO:
        return {**rec, "ok": False, "reason": f"short ({ratio:.2f} of baseline)"}
    if ratio > MAX_RATIO:
        return {**rec, "ok": False, "reason": f"long ({ratio:.2f} of baseline) - "
                                              f"extra speech around the word"}

    # Stage 3 - the entry has to be heard back as the word.
    heard = transcribe(session, key, got)
    if heard is None:
        rec.pop("v", None)                                   # unstamped: retry me
        return {**rec, "ok": False, "reason": "stt error"}
    ok, how = heard_matches(word, heard)
    rec["heard"] = heard
    if not ok:
        return {**rec, "ok": False, "reason": how}
    if ratio > LONG_RATIO:
        return {**rec, "ok": True, "how": how, "flag": f"long ({ratio:.2f})"}
    return {**rec, "ok": True, "how": how}


# ---------------------------------------------------------------------------
# validate
# ---------------------------------------------------------------------------

# requests.Session is not documented as thread-safe, so each worker gets its
# own rather than sharing one and hoping. Cheap next to three network calls.
_LOCAL = threading.local()


def worker_session():
    import requests
    sess = getattr(_LOCAL, "session", None)
    if sess is None:
        sess = _LOCAL.session = requests.Session()
    return sess


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

    # Two different reasons a word can be un-stamped, and conflating them
    # reads as alarming when it is routine.
    unstamped = [(w, v) for w, v in state.items() if v.get("v") != ORACLE_VERSION]
    retry = [w for w, v in unstamped if "error" in str(v.get("reason", ""))]
    stale = [w for w, v in unstamped if w not in set(retry)]
    if stale:
        print(f"note: {len(stale)} word(s) carry a verdict from an older, weaker gate "
              f"that could not\n      detect wrong-word entries. Queued for "
              f"re-validation, not trusted.")
    if retry:
        print(f"note: {len(retry)} word(s) previously hit a transient API error. "
              f"Queued for retry.")
    if stale or retry:
        print()

    # Scope. Default is the words the gate can actually prove; the rest are
    # written to a work-list and deferred, NOT silently dropped.
    get_cmu()
    covered = {w for w in cands if has_reference(w)}
    deferred = [w for w in cands if w not in covered]
    DEFERRED.write_text(
        "word,untrusted_phonemes\n" +
        "\n".join(f'"{w}","{cands[w]}"' for w in sorted(deferred)),
        encoding="utf-8")

    if args.scope == "covered":
        pool = [w for w in cands if w in covered]
    elif args.scope == "uncovered":
        pool = [w for w in cands if w not in covered]
    else:
        pool = list(cands)

    pending = [w for w in pool if state.get(w, {}).get("v") != ORACLE_VERSION]
    if args.offset:
        pending = pending[args.offset:]
    todo = pending[: args.limit] if args.limit else pending

    if not todo:
        print("Nothing left to validate.")
        return

    if args.scope == "covered":
        print(f"scope       : CMUdict-backed words only")
        print(f"deferred    : {len(deferred):,} words with no independent reference")
        print(f"              -> {DEFERRED}")
        print( "              g2p-en fabricates phonemes for these. They are NOT")
        print( "              in the dictionary and NOT proved - they fall back to")
        print( "              ElevenLabs' own reading until sourced properly.")
    else:
        print(f"scope       : {args.scope}  (includes words the gate cannot prove)")
    print()

    tts_chars = sum(len(w) * 2 + 60 for w in todo)
    print(f"to validate : {len(todo)} words")
    print(f"API calls   : {len(todo) * 2} TTS + {len(todo)} STT")
    print(f"~characters : {tts_chars:,}  <- TTS billing")
    # One STT call per word, on the tagged clip only. Single words run about
    # a second and a half, so this is an estimate, not a quote.
    print(f"~audio      : {len(todo) * 1.5 / 3600:.2f} h  <- STT billing (rough)")
    print(f"workers     : {args.workers}  (~{len(todo) * 3.0 / args.workers / 3600:.1f} h "
          f"at ~3s per word, vs ~{len(todo) * 3.0 / 3600:.1f} h sequential)")
    if not args.yes and input("Proceed? (y/N) ").strip().lower() not in ("y", "yes"):
        return

    OUT.mkdir(parents=True, exist_ok=True)
    get_cmu()      # load CMUdict once, on the main thread, before any fan-out
    get_g2p()      # same: g2p bootstraps lazily and is not worth racing on
    passed = failed = errors = 0
    done = 0
    lock = threading.Lock()

    def run_one(word):
        return word, judge(worker_session(), key, word, cands[word])

    # Bounded pool. Each word is three sequential calls that mostly sit waiting
    # on the network, so threads are the right tool - and the 429 backoff in
    # synth()/transcribe() is what keeps a wider pool from turning into a
    # rate-limit storm. Raise --workers only if you are not seeing retries.
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(run_one, w): w for w in todo}
        try:
            for fut in as_completed(futures):
                try:
                    word, res = fut.result()
                except Exception as e:  # noqa: BLE001 - one word must not kill the run
                    word = futures[fut]
                    res = {"ok": False, "reason": f"worker error: {e}"}  # unstamped
                with lock:
                    state[word] = res
                    done += 1
                    if res["ok"]:
                        passed += 1
                    elif "error" in res.get("reason", ""):
                        errors += 1
                    else:
                        failed += 1
                    if done % 25 == 0 or done == len(todo):
                        STATE.write_text(json.dumps(state, indent=1), encoding="utf-8")
                        print(f"  {done}/{len(todo)}  pass {passed}  reject {failed}  "
                              f"err {errors}", flush=True)
        except KeyboardInterrupt:
            # Save what is proved before unwinding - the whole point of a
            # resumable run is that stopping it costs nothing.
            with lock:
                STATE.write_text(json.dumps(state, indent=1), encoding="utf-8")
            print(f"\ninterrupted - {done} judged and saved. Re-run to continue.")
            pool.shutdown(wait=False, cancel_futures=True)
            return

    STATE.write_text(json.dumps(state, indent=1), encoding="utf-8")
    bad = [(w, v) for w, v in state.items() if not v.get("ok")]
    REJECTED.write_text(
        "word,phonemes,reason,heard,ratio\n" +
        "\n".join(f'"{w}","{cands.get(w,"")}","{v.get("reason","")}",'
                  f'"{v.get("heard","")}","{v.get("ratio","")}"' for w, v in bad),
        encoding="utf-8")
    flagged = [w for w, v in state.items() if v.get("ok") and v.get("flag")]
    print(f"\npassed {passed}   rejected {failed}   errors {errors}")
    if errors:
        print(f"the {errors} error(s) were NOT recorded as verdicts - re-run to retry them")
    print(f"rejections -> {REJECTED}")
    if flagged:
        print(f"{len(flagged)} passed but ran long - worth a listen: "
              f"{', '.join(sorted(flagged)[:8])}"
              f"{' ...' if len(flagged) > 8 else ''}")


# ---------------------------------------------------------------------------
# export
# ---------------------------------------------------------------------------

def cmd_export(args):
    if not (CANDIDATES.exists() and STATE.exists()):
        sys.exit("Run `generate` and `validate` first.")
    cands = json.loads(CANDIDATES.read_text(encoding="utf-8"))
    state = json.loads(STATE.read_text(encoding="utf-8"))
    proved = {w: v for w, v in state.items()
              if v.get("ok") and v.get("v") == ORACLE_VERSION and w in cands}
    # The length ceiling is applied here as well as in judge(), so entries
    # proved before the ceiling existed are re-filtered from their recorded
    # ratios rather than needing another paid run.
    overlong = {w: v for w, v in proved.items() if v.get("ratio", 1) > MAX_RATIO}
    good = {w: cands[w] for w in proved if w not in overlong}
    weak = sum(1 for v in state.values() if v.get("ok") and v.get("v") != ORACLE_VERSION)

    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<lexicon version="1.0" xmlns="http://www.w3.org/2005/01/pronunciation-lexicon"',
             '         alphabet="cmu-arpabet" xml:lang="en-US">']
    for w in sorted(good):
        lines.append(f"  <lexeme><grapheme>{escape(w)}</grapheme>"
                     f"<phoneme>{escape(good[w])}</phoneme></lexeme>")
    lines.append("</lexicon>")
    PLS.write_text("\n".join(lines), encoding="utf-8")

    deferred_n = sum(1 for w in cands if not has_reference(w))
    if overlong:
        print(f"excluded (long): {len(overlong)} entr(ies) whose clip ran over "
              f"{MAX_RATIO}x the word:")
        for w, v in sorted(overlong.items(), key=lambda t: -t[1].get("ratio", 0)):
            print(f"                 {w:20} {v.get('ratio')}x  heard "
                  f"{str(v.get('heard'))[:40]!r}")
    print(f"proved entries : {len(good)}")
    print(f"deferred       : {deferred_n:,} words with no independent reference "
          f"(see {DEFERRED.name})")
    if weak:
        print(f"excluded       : {weak} passed only the old length-only gate - "
              f"re-run `validate` to prove them")
    print(f"written        : {PLS}")
    print("\nUpload it in the ElevenLabs dashboard, then set on the Edge Function:")
    print("  USE_PRONUNCIATION_DICT=true")
    print("  PRONUNCIATION_DICT_ID=<id>")
    print("  PRONUNCIATION_DICT_VERSION=<version>")
    print("\nEvery entry in this file was spoken aloud with its phonemes and")
    print("heard back as the right word. Entries that went silent, ran short, or")
    print("came back as a different word are in rejected.csv and are NOT included.")


# ---------------------------------------------------------------------------
# selftest
# ---------------------------------------------------------------------------

OFFLINE_CASES = [
    # (headword, what the recogniser hears, should_pass, why it is here)
    ("fund",      "fund",            True,  "correct entry, heard back"),
    ("fund",      "Fund.",           True,  "punctuation and case must not matter"),
    ("fund",      "a fund",          True,  "Scribe pads single words into phrases"),
    ("fund",      "found",           False, "VALID ARPAbet, WRONG WORD - the hole"),
    ("fund",      "cue cue cue cue", False, "'Q Q Q Q' - passed the old gate at 1.33"),
    ("endowment", "endowment",       True,  "correct entry"),
    ("endowment", "department",      False, "VALID ARPAbet, WRONG WORD"),
    ("flour",     "flower",          True,  "homophone spelling - must NOT reject"),
    ("ate",       "eight",           True,  "homophone spelling - must NOT reject"),
    ("lead",      "lead",            True,  "heteronym - spelling still matches"),
    ("fund",      "",                False, "silence - the bug that shipped"),
]


def cmd_offline(args):
    """Exercise the matching rule with no API calls and no key.

    `selftest` proves the whole pipeline end to end and costs money. This
    proves the decision rule itself, instantly and free, so it can be run on
    every edit to this file. It is the check that caught the first version of
    heard_matches() comparing the transcript against the candidate phonemes
    instead of against the headword - a circular test that accepted "found"
    for "fund".
    """
    print(f"{'headword':11} {'heard':<18} {'verdict':7} {'via':<14} expectation")
    bad = 0
    for word, heard, should_pass, why in OFFLINE_CASES:
        got, how = heard_matches(word, heard)
        ok = got == should_pass
        bad += 0 if ok else 1
        print(f"{word:11} {heard!r:<18} {'pass' if got else 'REJECT':7} "
              f"{how[:13]:<14} {'OK ' if ok else 'WRONG'} - {why}")
    print()
    if bad:
        sys.exit(f"{bad} case(s) behaved unexpectedly - the gate is not sound.")
    print("The matching rule accepts correct and homophone-spelled transcripts")
    print("and rejects wrong-word, garbled and silent ones.")


def cmd_selftest(args):
    """Prove the validator actually rejects a broken entry.

    A gate that passes everything is worthless, and "200/200 passed" cannot
    tell those apart on its own. The cases below cover each way an entry can be
    wrong, including the one the length-only gate could not see: a well-formed
    ARPAbet string for a different word.
    """
    try:
        import requests
    except ImportError:
        sys.exit("pip install requests")
    key = os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        sys.exit("Set ELEVENLABS_API_KEY first.")
    session = requests.Session()
    get_cmu()

    cases = [
        ("fund",      "F AH1 N D",             True,  "correct ARPAbet"),
        ("fund",      "ˈfʌnd",       False, "espeak-ng IPA (the shipped bug)"),
        ("fund",      "Q Q Q Q",               False, "nonsense symbols"),
        ("fund",      "F AW1 N D",             False, "valid ARPAbet, WRONG WORD (found)"),
        ("endowment", "EH0 N D AW1 M AH0 N T", True,  "correct ARPAbet"),
        ("endowment", "D IH0 P AA1 R T M AH0 N T", False,
                                                      "valid ARPAbet, WRONG WORD (department)"),
        ("flour",     "F L AW1 ER0",           True,  "correct; Scribe may spell it 'flower'"),
    ]
    print(f"{'word':11} {'verdict':8} {'ratio':>6} {'heard':<14} expectation")
    bad = 0
    for word, ph, should_pass, why in cases:
        res = judge(session, key, word, ph)
        if res.get("reason", "").endswith("error"):
            print(f"{word:11} API ERROR ({res['reason']})")
            bad += 1
            continue
        accepted = bool(res["ok"])
        ok = accepted == should_pass
        bad += 0 if ok else 1
        print(f"{word:11} {'accept' if accepted else 'REJECT':8} "
              f"{res.get('ratio', 0):6.2f} {str(res.get('heard',''))[:13]:<14} "
              f"{'OK ' if ok else 'WRONG'} - {why}")
    print()
    if bad:
        print(f"{bad} case(s) behaved unexpectedly - do NOT trust the validation run.")
        sys.exit(1)
    print("The gate accepts correct entries and rejects silent, garbled and")
    print("wrong-word ones. A pass now means the word was heard back correctly.")
    print("Not proved by this gate: stress placement (REcord vs reCORD).")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("generate")
    v = sub.add_parser("validate")
    v.add_argument("--limit", type=int, default=0, help="validate at most N more words")
    v.add_argument("--offset", type=int, default=0,
                   help="skip N pending words first - use it to sample the rare tail")
    v.add_argument("--scope", choices=("covered", "uncovered", "all"), default="covered",
                   help="covered (default) = only words CMUdict can vouch for; "
                        "uncovered = the deferred tail; all = everything")
    v.add_argument("--workers", type=int, default=6,
                   help="words validated in parallel (default 6). Each is 3 API "
                        "calls; raise only if you are not seeing 429 retries")
    v.add_argument("--yes", action="store_true", help="skip the cost confirmation")
    sub.add_parser("export")
    sub.add_parser("selftest")
    sub.add_parser("offline")
    a = ap.parse_args()
    {"generate": cmd_generate, "validate": cmd_validate,
     "export": cmd_export, "selftest": cmd_selftest,
     "offline": cmd_offline}[a.cmd](a)
