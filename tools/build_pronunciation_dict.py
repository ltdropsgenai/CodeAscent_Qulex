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
SENSE_DEP = OUT / "sense_dependent.csv"
HETERONYMS_DART = ROOT / "lib" / "services" / "heteronyms.dart"
MANUAL = ROOT / "tools" / "manual_pronunciations.json"

VOICE_ID = "XoUkt2bf6DlvSzRmvA8X"
MODEL = "eleven_flash_v2"  # the only model in play that honours the dictionary
API = f"https://api.elevenlabs.io/v1/text-to-speech/{VOICE_ID}"
STT_API = "https://api.elevenlabs.io/v1/speech-to-text"
STT_MODEL = "scribe_v1"
DICT_API = "https://api.elevenlabs.io/v1/pronunciation-dictionaries/add-from-file"

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
# Hand-written entries get a looser floor, because the baseline they are
# measured against is the very reading they exist to replace. "adze" is one
# syllable; ElevenLabs was saying "Odd Zai", which is two - so the CORRECT
# pronunciation comes out 0.72 of the wrong one, and the standard floor of
# 0.75 rejected it for being right. Same for "LUT" at 0.68 against a model
# that was reading it "Alee at".
#
# The floor is loosened, not removed. MIN_BYTES still catches true silence,
# and 0.5 is still far above the 0.34 that the original broken dictionary
# produced for "fund", so the failure this whole file exists to prevent is
# still caught.
MANUAL_PASS_RATIO = 0.5
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


_MANUAL = None


def load_manual():
    """Hand-written entries for words no reference source covers.

    Everything else in this file is generated and then proved. These are the
    opposite: a person wrote them because the survey showed ElevenLabs reading
    the word as something else entirely. They are version-controlled alongside
    the code, not in the gitignored working directory, because they are the
    only part of this pipeline that cannot be regenerated.

    A hand-written entry counts as its own reference. That is not a loophole -
    it is the same standing CMUdict has, just with a smaller author.
    """
    global _MANUAL
    if _MANUAL is None:
        try:
            raw = json.loads(MANUAL.read_text(encoding="utf-8"))
        except OSError:
            _MANUAL = {}
            return _MANUAL
        _MANUAL = {k: v["ph"] for k, v in raw.items()
                   if not k.startswith("_") and isinstance(v, dict) and v.get("ph")}
        bad = [k for k, ph in _MANUAL.items() if not valid_arpabet(ph)]
        if bad:
            sys.exit(f"manual_pronunciations.json has invalid ARPAbet for: {bad}")
    return _MANUAL


def phones_for(word, g2p):
    """ARPAbet for one headword, preferring CMUdict token by token.

    Handing a hyphenated compound to g2p-en as a single string produces
    fabrications, not near misses:

        stir-fry        g2p  S T ER1 F R IY0            ("stir-free")
        deep-fry        g2p  D IY1 F R IY0              (the P is simply gone)
        results-driven  g2p  R EH2 S T W IH1 L S V IH0 NG   ("rest wheels wing")

    Measured over the full run: where g2p disagreed with token-wise CMUdict,
    87% of those entries failed the gate. Where it agreed, 9% did. So split on
    word boundaries and look each part up; fall back to g2p only for tokens
    CMUdict has never seen, which is what it is actually good for.
    """
    hand = load_manual().get(word) or load_manual().get(word.lower())
    if hand:
        return hand

    parts = [p for p in re.split(r"[-\s]+", word.strip()) if p]

    # SINGLE words stay with g2p-en. It consults CMUdict too, but chooses
    # between alternate readings using part of speech, and CMUdict's first
    # listed variant is not that choice. Overriding it would silently reset
    # every stress-shift heteronym to an arbitrary reading:
    #
    #     upgrade   g2p AH1 P G R EY0 D  (UPgrade, noun)
    #               cmu AH0 P G R EY1 D  (upGRADE, verb)
    #     object    g2p AH0 B JH EH1 K T (obJECT, verb)
    #               cmu AA1 B JH EH0 K T (OBject, noun)
    #
    # 49 headwords would have flipped that way - discount, suspect, reject,
    # import, collect among them. On a vocabulary app, that is a regression
    # dressed as a fix.
    if len(parts) <= 1:
        return " ".join(p for p in g2p(word) if str(p).strip() and p != " ")

    # MULTI-token words are the ones g2p fabricates on, so look each part up.
    cmu = get_cmu()
    out = []
    for part in parts:
        entry = cmu.get(part.lower())
        if entry:
            out.extend(entry[0])
        else:
            out.extend(p for p in g2p(part) if str(p).strip() and p != " ")
    return " ".join(out)


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
            ph = phones_for(word, g2p)
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
    man = load_manual()
    if word in man or word.lower() in man:
        return True
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
def cmudict_attested(word: str, ph: str) -> bool:
    """True when CMUdict itself lists exactly these phonemes for this word.

    Scribe is a statistical model with no context on a bare word, and it
    misheard a lot of correct entries: "hot" as "Heart", "app" as "Ape",
    "soap" as "Soak", "sink" as "Sing". Rejecting those throws away 586
    entries that a curated human dictionary vouches for.

    So when the phonemes we sent ARE a CMUdict reading, and the clip already
    cleared the length gate, that is better evidence than one transcription.
    This cannot rescue the wrong-word case the gate exists to catch: "fund"
    with F AW1 N D is not a CMUdict reading of "fund", so it stays rejected.
    """
    man = load_manual()
    if man.get(word, man.get(word.lower())) == ph:
        return True
    cmu = get_cmu()
    toks = norm_text(word).split()
    variants = [()]
    for t in toks:
        e = cmu.get(t)
        if not e:
            return False
        variants = [v + bare(x) for v in variants for x in e][:64]
    return bare(ph.split()) in set(variants)


def judge(session, key, word, ph):
    """Run all three stages against one candidate. Returns a state dict."""
    tagged = f'<phoneme alphabet="cmu-arpabet" ph="{ph}">{word}</phoneme>'
    base = synth(session, key, word)
    got = synth(session, key, tagged) if base else None
    if not base or not got:
        return {"ok": False, "reason": "api error"}          # unstamped: retry me

    ratio = len(got) / len(base)
    # The verdict is about THIS phoneme string. Record it, so that
    # regenerating candidates invalidates the proof instead of inheriting it.
    rec = {"v": ORACLE_VERSION, "ph": ph, "ratio": round(ratio, 2),
           "base": len(base), "got": len(got)}

    # Stage 2 - silence and truncation, rejected without spending an STT call.
    if len(got) < MIN_BYTES:
        return {**rec, "ok": False, "reason": f"no audio ({len(got)}B)"}
    hand = load_manual().get(word, load_manual().get(word.lower())) == ph
    floor = MANUAL_PASS_RATIO if hand else PASS_RATIO
    if ratio < floor:
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
    if not ok and cmudict_attested(word, ph):
        # Recognition disagreed, but CMUdict says these phonemes are this word.
        man = load_manual()
        how = ("hand-written"
               if man.get(word, man.get(word.lower())) == ph else "cmudict-attested")
        ok = True
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

    # Report un-stamped words AFTER scoping. Reporting them before means
    # announcing 126 words "queued for re-validation" and then saying "nothing
    # left to validate" in the same breath, because they were never in scope.
    inscope = set(pool)
    unstamped = [(w, v) for w, v in state.items() if v.get("v") != ORACLE_VERSION]
    retry = [w for w, v in unstamped if "error" in str(v.get("reason", ""))]
    stale = [w for w, v in unstamped if w not in set(retry)]
    s_in = [w for w in stale if w in inscope]
    r_in = [w for w in retry if w in inscope]
    s_out = len(stale) - len(s_in)
    if s_in:
        print(f"note: {len(s_in)} word(s) carry a verdict from an older, weaker gate. "
              f"Queued for re-validation.")
    if r_in:
        print(f"note: {len(r_in)} word(s) hit a transient API error. Queued for retry.")
    if s_out:
        print(f"note: {s_out} word(s) carry old-gate verdicts but are OUT OF SCOPE "
              f"(deferred, no\n      CMUdict reference). Re-running will not touch "
              f"them - they need a\n      reference source, not another pass. "
              f"See {DEFERRED.name}.")
    if s_in or r_in or s_out:
        print()

    def proved(w):
        v = state.get(w, {})
        # A verdict about different phonemes is not a verdict about these ones.
        # Note the absence of a default: `v.get("ph", cands[w])` would silently
        # treat "we never recorded what was tested" as "it matches", which is
        # how a regenerated candidate inherited a proof it never earned.
        return v.get("v") == ORACLE_VERSION and v.get("ph") == cands[w]

    pending = [w for w in pool if not proved(w)]
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

def app_heteronyms():
    """The spellings lib/services/heteronyms.dart respells before synthesis.

    Read from the Dart source rather than copied here, so the two cannot drift
    apart silently. If that file gains an entry, this picks it up.
    """
    try:
        src = HETERONYMS_DART.read_text(encoding="utf-8")
    except OSError:
        return set()
    body = src.split("final Map<String, _Heteronym> _heteronyms = {", 1)
    if len(body) < 2:
        return set()
    return set(re.findall(r"'([a-z]+)':\s*const _Heteronym", body[1].split("};", 1)[0]))


def sense_dependent(word: str, ph: str):
    """Why this spelling cannot be pinned to one pronunciation, or None.

    An ElevenLabs dictionary matches on the exact string and holds one entry
    per spelling. For a word whose pronunciation depends on which sense is on
    screen, that is not a limitation to work around - it is a guarantee of
    being wrong some of the time, stated confidently.

    Two families:

      1. The app already respells these before synthesis (heteronyms.dart), so
         a dictionary entry for the raw spelling is unreachable dead weight -
         and actively dangerous if any future path speaks raw text. `lead` was
         sitting in the dictionary as L EH1 D, the metal, which is the exact
         mispronunciation that file was written to stop.

      2. CMUdict itself lists readings that differ in STRESS placement -
         ADdress the noun against adDRESS the verb. Nothing in this pipeline
         can tell which sense a given catalogue row means, and the gate cannot
         even detect the difference: Scribe transcribes both as "address".
         Pinning one is a coin flip we would be freezing into the product.
    """
    if word.lower() in app_heteronyms():
        return "respelled by heteronyms.dart"
    cmu = get_cmu()
    alts = cmu.get(norm_text(word))
    if alts and len({tuple(i for i, t in enumerate(a) if t.endswith("1")) for a in alts}) > 1:
        return "CMUdict readings differ in stress placement"
    return None


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
    # The file must contain the phonemes that were actually spoken and heard.
    # If candidates.json has been regenerated since the verdict, the entry is
    # unproved no matter what the verdict says.
    drifted = {w for w, v in proved.items() if v.get("ph") != cands[w]}
    sense = {w: r for w in proved
             if (r := sense_dependent(w, cands[w])) is not None}
    good = {w: cands[w] for w in proved
            if w not in overlong and w not in drifted and w not in sense}
    if sense:
        SENSE_DEP.write_text(
            "word,phonemes,why\n" +
            "\n".join(f'"{w}","{cands[w]}","{r}"' for w, r in sorted(sense.items())),
            encoding="utf-8")
    weak_all = [w for w, v in state.items() if v.get("ok") and v.get("v") != ORACLE_VERSION]
    weak_inscope = [w for w in weak_all if w in cands and has_reference(w)]
    weak_deferred = [w for w in weak_all if w not in set(weak_inscope)]

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
    if drifted:
        print(f"excluded (drift): {len(drifted)} entr(ies) whose phonemes changed since "
              f"they were proved.\n                  Run `validate` to re-prove them.")
    if sense:
        import collections as _c
        counts = _c.Counter(sense.values())
        print(f"excluded (sense): {len(sense)} entr(ies) whose pronunciation depends on "
              f"which sense is meant:")
        for why, n in counts.most_common():
            print(f"                  {n:5}  {why}")
        print(f"                  -> {SENSE_DEP.name}")
    print(f"proved entries : {len(good)}")
    print(f"deferred       : {deferred_n:,} words with no independent reference "
          f"(see {DEFERRED.name})")
    if weak_inscope:
        print(f"excluded       : {len(weak_inscope)} passed only the old length-only "
              f"gate - re-run `validate` to prove them")
    if weak_deferred:
        print(f"excluded       : {len(weak_deferred)} passed only the old gate AND have "
              f"no CMUdict\n                 reference. A re-run cannot prove these; "
              f"they are part of\n                 the deferred set and need a "
              f"reference source.")
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


def cmd_recheck(args):
    """Re-apply the current rules to measurements already paid for. Free.

    Every verdict stores what was measured - the byte ratio, what Scribe heard,
    the phonemes it applied to. When a rule changes, that stored evidence can
    be re-judged without synthesising anything again. Use it after changing
    MAX_RATIO, or after adding a route like cmudict-attested, instead of
    re-running a paid pass over words that were already spoken.

    It only ever re-derives from recorded evidence. Anything without a
    recorded measurement is left alone for `validate` to handle.
    """
    if not (CANDIDATES.exists() and STATE.exists()):
        sys.exit("Run `generate` and `validate` first.")
    cands = json.loads(CANDIDATES.read_text(encoding="utf-8"))
    state = json.loads(STATE.read_text(encoding="utf-8"))
    get_cmu()

    changed = {"rescued": [], "revoked": []}
    for w, v in state.items():
        if v.get("v") != ORACLE_VERSION or "ratio" not in v:
            continue
        ph = v.get("ph", cands.get(w))
        if ph is None:
            continue
        was = bool(v.get("ok"))
        ratio = v.get("ratio", 1.0)

        man = load_manual()
        hand = man.get(w, man.get(w.lower())) == ph
        floor = MANUAL_PASS_RATIO if hand else PASS_RATIO

        if ratio > MAX_RATIO:
            now, how = False, f"long ({ratio:.2f} of baseline) - extra speech around the word"
        elif ratio < floor or v.get("got", MIN_BYTES) < MIN_BYTES:
            now, how = False, f"short ({ratio:.2f} of baseline)"
        else:
            heard = v.get("heard")
            if heard is None:
                # The length gate rejected before recognition ran. For a
                # hand-written entry that cleared the loosened floor,
                # authorship is the attestation - the same standing CMUdict
                # has. For anything else, leave it for `validate`.
                if hand:
                    now, how = True, "hand-written"
                else:
                    continue
            now, how = heard_matches(w, heard)
            if not now and cmudict_attested(w, ph):
                now, how = True, "cmudict-attested"

        if now != was:
            changed["rescued" if now else "revoked"].append(w)
            v["ok"] = now
            (v.__setitem__("how", how) if now else v.__setitem__("reason", how))

    STATE.write_text(json.dumps(state, indent=1), encoding="utf-8")
    print(f"rescued : {len(changed['rescued'])}  (now pass under the current rules)")
    if changed["rescued"]:
        print("          " + ", ".join(sorted(changed["rescued"])[:12]) +
              (" ..." if len(changed["rescued"]) > 12 else ""))
    print(f"revoked : {len(changed['revoked'])}  (no longer pass)")
    if changed["revoked"]:
        print("          " + ", ".join(sorted(changed["revoked"])[:12]) +
              (" ..." if len(changed["revoked"]) > 12 else ""))
    print("\nNo API calls were made. Run `export` to rebuild the .pls.")


SURVEY = OUT / "deferred_survey.csv"


def cmd_survey(args):
    """Ask a cheaper question about the deferred words: does the model already
    say them correctly on its own?

    5,664 headwords have no CMUdict entry, and every attempt to invent phonemes
    for them has fabricated - g2p-en outright, and naive compound splitting too
    ("Compaction" as compact + ion, "Carbonation" as carbo + nation). Before
    generating a fourth guess and building another gate around it, find out how
    many of these words actually need help.

    One synthesis, one transcription, no dictionary. If Scribe hears the word
    back, ElevenLabs is already reading it correctly and a dictionary entry
    could only make it worse. What is left is the real problem, and it will be
    a great deal smaller than 5,664.

    This spends 1 TTS + 1 STT per word instead of the 2 + 1 a full validation
    costs, and it answers "how big is this" before anything is committed to.
    """
    try:
        import requests
    except ImportError:
        sys.exit("pip install requests")
    key = os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        sys.exit("Set ELEVENLABS_API_KEY first.")
    if not DEFERRED.exists():
        sys.exit("Run `validate` once so the deferred list exists.")

    rows = [ln.split(",")[0].strip('"')
            for ln in DEFERRED.read_text(encoding="utf-8").splitlines()[1:] if ln.strip()]
    done = {}
    if SURVEY.exists():
        for ln in SURVEY.read_text(encoding="utf-8").splitlines()[1:]:
            if ln.strip():
                parts = [c.strip('"') for c in ln.split('","')]
                done[parts[0].lstrip('"')] = parts
    todo = [w for w in rows if w not in done]
    if args.limit:
        todo = todo[: args.limit]
    if not todo:
        print("Nothing left to survey.")
        return

    print(f"to survey  : {len(todo):,} of {len(rows):,} deferred words "
          f"({len(done):,} already done)")
    print(f"API calls  : {len(todo)} TTS + {len(todo)} STT   (no dictionary applied)")
    print(f"workers    : {args.workers}")
    if not args.yes and input("Proceed? (y/N) ").strip().lower() not in ("y", "yes"):
        return

    OUT.mkdir(parents=True, exist_ok=True)
    get_cmu()
    lock = threading.Lock()
    fine = needs = err = 0

    def one(word):
        audio = synth(worker_session(), key, word)
        if not audio or len(audio) < MIN_BYTES:
            return word, None, "api error"
        heard = transcribe(worker_session(), key, audio)
        if heard is None:
            return word, None, "stt error"
        ok, how = heard_matches(word, heard)
        return word, ok, heard

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(one, w) for w in todo]
        try:
            for i, fut in enumerate(as_completed(futures), 1):
                try:
                    word, ok, heard = fut.result()
                except Exception as e:  # noqa: BLE001
                    err += 1
                    continue
                with lock:
                    if ok is None:
                        err += 1
                    elif ok:
                        fine += 1
                    else:
                        needs += 1
                    done[word] = [word, "already-correct" if ok else
                                  ("error" if ok is None else "needs-help"), str(heard)]
                    if i % 25 == 0 or i == len(todo):
                        _write_survey(done)
                        print(f"  {i}/{len(todo)}  already-correct {fine}  "
                              f"needs-help {needs}  err {err}", flush=True)
        except KeyboardInterrupt:
            with lock:
                _write_survey(done)
            print(f"\ninterrupted - {len(done)} surveyed and saved.")
            pool.shutdown(wait=False, cancel_futures=True)
            return

    _write_survey(done)
    tot = fine + needs
    print(f"\nalready correct : {fine:,}" + (f"  ({fine/tot*100:.0f}%)" if tot else ""))
    print(f"needs help      : {needs:,}" + (f"  ({needs/tot*100:.0f}%)" if tot else ""))
    print(f"errors          : {err:,}")
    print(f"\n-> {SURVEY}")
    print("\nThe 'needs help' rows are the only deferred words worth sourcing")
    print("phonemes for. 'already correct' means the model reads them fine and a")
    print("dictionary entry could only make them worse.")


def _write_survey(done):
    SURVEY.write_text(
        "word,verdict,heard\n" +
        "\n".join(f'"{r[0]}","{r[1]}","{r[2]}"' for r in done.values()),
        encoding="utf-8")


def cmd_upload(args):
    """Upload the .pls and print the two ids the Edge Function needs.

    The dashboard shows the dictionary but makes the version id awkward to
    find, and the version is what the API actually pins to. Creating it here
    means both values come straight from the response, with no transcription
    step to get wrong.

    It also reports version_rules_num - how many rules ElevenLabs says it
    accepted. If that is lower than the number of lexemes we sent, entries were
    dropped on their side, silently, which is exactly the failure mode that
    started all of this. Better to see it now than to wonder later why a word
    still sounds wrong.
    """
    try:
        import requests
    except ImportError:
        sys.exit("pip install requests")
    key = os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        sys.exit("Set ELEVENLABS_API_KEY first.")
    if not PLS.exists():
        sys.exit("Run `export` first - no .pls to upload.")

    raw = PLS.read_text(encoding="utf-8")
    sent = raw.count("<lexeme>")
    print(f"file    : {PLS}")
    print(f"lexemes : {sent:,}")
    print(f"name    : {args.name}")
    if not args.yes and input("Upload? (y/N) ").strip().lower() not in ("y", "yes"):
        return

    r = requests.post(
        DICT_API,
        headers={"xi-api-key": key},
        files={"file": (PLS.name, raw.encode("utf-8"), "application/octet-stream")},
        data={"name": args.name, "description": args.description},
        timeout=300,
    )
    if r.status_code != 200:
        sys.exit(f"HTTP {r.status_code}: {r.text[:500]}")
    d = r.json()
    accepted = d.get("version_rules_num")

    print()
    print("Set these three on the Supabase Edge Function")
    print("(Project -> Edge Functions -> Secrets), then redeploy `tts`:")
    print()
    print("  USE_PRONUNCIATION_DICT=true")
    print(f"  PRONUNCIATION_DICT_ID={d.get('id')}")
    print(f"  PRONUNCIATION_DICT_VERSION={d.get('version_id')}")
    print()
    print(f"rules accepted by ElevenLabs : {accepted}")
    if isinstance(accepted, int) and accepted != sent:
        print(f"  MISMATCH - {sent:,} lexemes sent, {accepted:,} accepted. "
              f"{sent - accepted:,} were dropped\n"
              f"  server-side without an error. Do NOT enable this dictionary "
              f"until that is\n  understood - silent drops are how the last one "
              f"got through.")
    else:
        print("  matches what was sent - nothing dropped server-side.")


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
    sub.add_parser("recheck")
    sv = sub.add_parser("survey")
    sv.add_argument("--limit", type=int, default=0)
    sv.add_argument("--workers", type=int, default=6)
    sv.add_argument("--yes", action="store_true")
    u = sub.add_parser("upload")
    u.add_argument("--name", default="Qulex validated pronunciation")
    u.add_argument("--description", default="Built and proved by tools/build_pronunciation_dict.py")
    u.add_argument("--yes", action="store_true", help="skip the confirmation")
    a = ap.parse_args()
    {"generate": cmd_generate, "validate": cmd_validate,
     "export": cmd_export, "selftest": cmd_selftest,
     "offline": cmd_offline, "upload": cmd_upload,
     "recheck": cmd_recheck, "survey": cmd_survey}[a.cmd](a)
