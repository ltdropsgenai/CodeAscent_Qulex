#!/usr/bin/env python3
"""Build a listening survey for words whose pronunciation nobody has heard.

    python tools/pronunciation_survey.py build --top 100
    # open tools/pronunciation/survey.html, listen, click, download verdicts.json
    python tools/pronunciation_survey.py merge tools/pronunciation/verdicts.json

WHY THIS EXISTS

build_pronunciation_dict.py validates an entry by synthesizing it and asking
Scribe to transcribe the clip back. That gate catches a word read as a
DIFFERENT word — "fund" heard as "found" — and it is genuinely good at that.
It cannot catch a word read as the SAME word with the wrong stress or the
wrong vowel, because speech-to-text returns orthography. Its own header says
so: "REcord vs reCORD both transcribe as record", and "the only detector we
have is a person listening".

4,039 headwords passed that gate with the verdict `already-correct` and were
never given a dictionary entry. `detritivore` is one of them, and on 21 Aug a
learner heard it spoken wrong. The verdict was never evidence; it was the
absence of one particular kind of evidence.

This tool builds the missing detector. It synthesizes the candidates through
the same Edge Function the app uses — so what you hear is exactly what a
learner hears, not a lab approximation — and lays them out as a page you can
work through with two keys. It records what a person heard. Nothing else in
this repository can do that.

COST. Each word is one synthesis (headwords have never been warmed), roughly
7 credits each, and the admin token bypasses the daily budget. 100 words is
about 750 credits and 30 seconds. The clips stay in the cache afterwards, so
the survey is also a small warming run.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import random
import re
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from html import escape
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PRON = ROOT / "tools" / "pronunciation"
RISK = PRON / "risk.csv"
def carrier_slug(carrier: str) -> str:
    """A short readable id for a frame: "The word is {word}." -> "the-word-is"."""
    words = re.findall(r"[a-z]+", carrier.replace("{word}", " ").lower())
    return "-".join(words)[:32] or "frame"


def survey_path(batch: str) -> Path:
    """One file per batch. The first version wrote every build to survey.html,
    so running two builds back to back silently destroyed the first — which is
    exactly what happened on 21 Aug, after the clips had already been paid for.
    """
    return PRON / f"survey-{batch}.html"


LEDGER = PRON / "verdict_ledger.json"
CATALOGUE = ROOT / "assets" / "words.json"

_CAT: dict | None = None
_RANK: dict = {}
_FIXED: set = set()


def catalogue_meta() -> dict:
    """Difficulty for every headword, for the ones risk.csv leaves out.

    risk.csv holds 3,784 words; the catalogue holds 16,808. --words used to
    silently skip anything outside the smaller file, which on 3 Sep dropped 19
    of 60 requested words — including `mullite`, the known-wrong anchor the
    batch was built around, and two of the five words in a recorded prediction.
    A survey tool that quietly declines to survey what it was asked to survey
    is worse than one that errors.
    """
    global _CAT
    if _CAT is None:
        _CAT = {}
        try:
            for w in json.loads(CATALOGUE.read_text(encoding="utf-8")):
                _CAT[w["word"].lower()] = {
                    "word": w["word"],
                    "difficulty": w.get("difficulty", ""),
                    "traps": "",
                    "espeak_untrusted_guess": "",
                }
                _RANK[w["word"].lower()] = w.get("freqRank") or 10 ** 6
                if w.get("say"):
                    _FIXED.add(w["word"].lower())
        except (OSError, ValueError):
            pass
    return _CAT


def fixed_words() -> set:
    """Words that already carry a `say` override - permanently barred from
    being used as a control.

    7 Sep 2026, at the user's instruction, and he was right to give it.
    Controls were drawn from the verdict ledger's settled words, and the
    settled-WRONG set was exactly four entries - lahar, paratope, sangha,
    sarcomere - every one of them a word he had personally reported, judged
    twice, and watched us fix. Every batch drew three of those four. So the
    reward for finding a mispronunciation was to be made to listen to it
    again, forever, in every batch after.

    Worse, it had stopped being measurement. A control works only while the
    listener cannot tell it from the words under test; once he could name them
    on sight he was scoring his memory, not his ear. We were charging him time
    for data we had stopped collecting.

    A fixed word is finished. It does not come back.
    """
    catalogue_meta()
    return _FIXED


def controls_path(batch: str) -> Path:
    """What a batch's hidden controls were. Written at build, read at merge.

    It is a sidecar rather than a field in the page because the page must not
    know which items are controls - anything it knows can leak into the layout,
    and a control the listener can identify is not a control.
    """
    return PRON / f"controls-{batch}.json"


def load_ledger() -> dict:
    if not LEDGER.exists():
        return {}
    try:
        return json.loads(LEDGER.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_ledger(led: dict) -> None:
    PRON.mkdir(parents=True, exist_ok=True)
    LEDGER.write_text(json.dumps(led, indent=1, sort_keys=True), encoding="utf-8")


MANGLE = (
    # Each recipe breaks a word in a DIFFERENT way, so a listener cannot learn
    # "the odd one out always has an extra syllable at the end" and start
    # scoring the recipe instead of the sound.
    ("a spurious final syllable", lambda w: w + "uh"),
    ("a spurious syllable in the middle", lambda w: w[:3] + "uh" + w[3:]),
    ("the first vowel replaced", lambda w: _swap_first_vowel(w)),
)


def _swap_first_vowel(w: str) -> str:
    for i, ch in enumerate(w):
        if ch in "aeiou":
            return w[:i] + "oo" + w[i + 1:]
    return w + "uh"


def manufacture_controls(exclude: set, n: int, batch: str
                         ) -> tuple[list[dict], dict]:
    """Controls built to order from words nobody has judged, instead of drawn
    from the ledger's handful of settled ones.

    THE PROBLEM THIS REPLACES. Controls used to be past verdicts replayed. That
    works exactly once. The settled-wrong pool was four words, all of them
    words the user had reported and we had fixed, so every batch made him
    re-listen to the same three - and once he could recognise them they stopped
    being controls at all. See fixed_words().

    THE CONSTRUCTION. A control needs a clip whose correct verdict is known
    before anyone listens. It does not need a word with a history. So: take an
    ordinary high-frequency word nobody has ever judged. Spoken plainly, the
    engine says it correctly - `harbor` is not where these voices fail - and
    the expected verdict is `right`. Spoken through one of the MANGLE recipes,
    it is unambiguously broken and the expected verdict is `wrong`. The word on
    the label is real either way, so nothing about the row gives it away.

    That makes the supply unbounded and non-repeating. With ~1,200 eligible
    words and six per batch, a word recurs about every two hundred batches.

    THE CAVEAT, stated because nobody else will. A manufactured error may be
    easier to catch than a natural one - `harboruh` is more obviously wrong
    than a subtly misstressed `sarcomere`. If so, control agreement will read
    higher than the listener's true reliability, and the CONTROL_FLOOR becomes
    a weaker guard than it looks. It is not a fake guard: a listener who cannot
    hear `harboruh` is not listening at all, and that is the failure mode that
    matters most. But do not read 100% agreement as proof of a fine ear.
    """
    cat = catalogue_meta()
    led = load_ledger()
    banned = fixed_words() | set(led) | {w.lower() for w in exclude}
    pool = sorted(w for w in cat
                  if w not in banned
                  and _RANK.get(w, 10 ** 6) <= 2500
                  and w.isalpha() and 4 <= len(w) <= 12)
    if len(pool) < n:
        return [], {}
    # Seeded from the BATCH NAME, not from --seed. --seed defaults to 1, so
    # seeding from it would hand every batch the same six control words and
    # reintroduce the exact problem this function exists to remove. The batch
    # name is a digest of what was asked for, so a different request draws
    # different controls and REBUILDING the same request draws the same ones —
    # which is what makes a rebuild resume the verdicts already entered.
    rng = random.Random(int(hashlib.sha256(batch.encode()).hexdigest()[:8], 16))
    picked = rng.sample(pool, n)
    rows, expected = [], {}
    for i, w in enumerate(picked):
        base = dict(cat[w])
        if i < n // 2:                      # half broken on purpose
            base["speak"] = MANGLE[i % len(MANGLE)][1](w)
            expected[w] = "wrong"
        else:                               # half left alone
            expected[w] = "right"
        rows.append(base)
    return rows, expected



MANUAL = ROOT / "tools" / "manual_pronunciations.json"
# Below this, a batch's controls have failed and the batch is not merged.
# 24 Aug: a batch judged unblind reproduced 4 of 9 of its own prior failures.
CONTROL_FLOOR = 0.80
DEFAULT_URL = "https://fzhguqoodojugeuyosnj.supabase.co"


def die(msg: str) -> "None":
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(1)


def synth(base: str, anon: str, admin: str, text: str,
          accent: str = "us") -> tuple[bool, str, str]:
    """Returns (ok, public_url, detail). Same call the app makes.

    The accent goes on the wire because the voice id is part of the cache
    key on both sides. A respelling verified against one voice says nothing
    about the other: "sarcomeer" is tuned to how Victoria reads it, and
    James Oxford may not read it the same way.
    """
    req = urllib.request.Request(
        f"{base}/functions/v1/tts",
        data=json.dumps({"text": text, "lang": "en", "accent": accent})
        .encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {anon}",
            "apikey": anon,
            "x-admin-token": admin,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            body = json.loads(r.read().decode("utf-8"))
            url = body.get("url")
            if not url:
                return False, "", f"no url in response: {str(body)[:120]}"
            return True, url, "cached" if body.get("cached") else "new"
    except urllib.error.HTTPError as e:
        return False, "", f"HTTP {e.code}: {e.read().decode('utf-8','replace')[:160]}"
    except Exception as e:  # noqa: BLE001
        return False, "", str(e)


def load_risk(args: argparse.Namespace) -> tuple[list[dict], str]:
    """Selects what to survey. Three modes, and the third is the honest one.

    --top N       the highest-scoring N. Finds faults fast, but the rate you
                  measure is not the population rate.
    --words a,b   an explicit list, for testing a hypothesis (all the -ative
                  words, say) or for re-checking a known failure as a control.
    --sample N    N drawn at random with a fixed seed. This is the only mode
                  that answers "how bad is it overall", because the others
                  choose their own evidence.
    """
    if not RISK.exists():
        die(f"cannot find {RISK}. Generate the ranked risk list first.")
    rows = list(csv.DictReader(RISK.open(encoding="utf-8")))
    if not rows:
        die(f"{RISK} is empty")

    if getattr(args, "say", None):
        # Verify a respelling the way the APP will speak it, not the way the
        # catalogue spells it. Word.say replaces the synthesis text at runtime,
        # so a survey of the headword tests something the learner never hears —
        # which is why the five overrides in build 44 shipped unverified.
        # The row is LABELLED with the headword and SPOKEN as the respelling,
        # so the listener judges "did that sound like sarcomere?" without being
        # told what trick produced it.
        pairs = []
        for chunk in args.say.split(","):
            if "=" not in chunk:
                die(f"--say wants word=respelling, got {chunk!r}")
            head, _, spoken = chunk.partition("=")
            pairs.append((head.strip(), spoken.strip()))
        if not pairs:
            die("--say listed nothing")
        by = {r["word"].lower(): r for r in rows}
        picked = []
        for head, spoken in pairs:
            base = dict(by.get(head.lower()) or {"word": head, "difficulty": ""})
            base["word"] = head
            base["speak"] = spoken
            picked.append(base)
        digest = hashlib.sha256(args.say.encode()).hexdigest()[:8]
        return picked, f"say-{digest}"

    if args.words:
        want = [w.strip().lower() for w in args.words.split(",") if w.strip()]
        by = {r["word"].lower(): r for r in rows}
        cat = catalogue_meta()
        picked, from_cat, invented = [], [], []
        for w in want:
            if w in by:
                picked.append(by[w])
            elif w in cat:
                picked.append(dict(cat[w]))
                from_cat.append(w)
            else:
                # Not a catalogue word at all — still synthesize it. That is how
                # a respelling candidate gets heard before it becomes a `say`.
                picked.append({"word": w, "difficulty": "",
                               "traps": "", "espeak_untrusted_guess": ""})
                invented.append(w)
        if from_cat:
            print(f"{len(from_cat)} not in the risk list, taken from the "
                  f"catalogue instead: {', '.join(from_cat)}")
        if invented:
            print(f"{len(invented)} not in the catalogue, synthesized as given: "
                  f"{', '.join(invented)}")
        if not picked:
            die("no words given")
        # The name carries a digest of the list. Two --words batches used to
        # both write survey-words.html, and the second destroyed the first
        # after its clips had been paid for. Anything that changes the audio
        # has to change the filename.
        digest = hashlib.sha256(",".join(sorted(want)).encode()).hexdigest()[:8]
        return picked, f"words-{digest}"

    if args.sample:
        # Seeded, so a rate can be re-measured against the same draw later.
        rng = random.Random(args.seed)
        return rng.sample(rows, min(args.sample, len(rows))), f"sample{args.sample}-seed{args.seed}"

    if args.traps:
        picked = [r for r in rows if r.get("traps")]
        print(f"{len(picked)} words carry an orthographic trap")
        return (picked[: args.top] if args.top else picked), "traps"

    return rows[: args.top], f"top{args.top}"


def cmd_build(args: argparse.Namespace) -> None:
    anon = os.environ.get("SUPABASE_ANON_KEY", "")
    admin = os.environ.get("TTS_ADMIN_TOKEN", "")
    if not anon:
        die("SUPABASE_ANON_KEY is not set (the public key in supabase_config.dart)")
    if not admin:
        die("TTS_ADMIN_TOKEN is not set — without it every request is charged "
            "against the 600/day budget and the survey would exhaust it")
    base = os.environ.get("SUPABASE_URL", DEFAULT_URL).rstrip("/")

    rows, batch = load_risk(args)
    if getattr(args, "accent", "us") != "us":
        # Anything that changes the audio has to change the filename. This rule
        # was learned twice: two --words batches once wrote the same file and
        # the second destroyed the first after its clips were paid for.
        batch = f"{batch}-{args.accent}"

    # Controls are the default, not a flag you remember to pass. A batch that
    # cannot reproduce its own known verdicts is not evidence about the words
    # it was built to measure.
    control_map: dict = {}
    if args.controls > 0 and not args.no_controls:
        # Scale to the batch. Six controls in an eleven-row batch is 55%
        # overhead for a guard that does not get six times better.
        want = min(args.controls, max(2, len(rows) // 5))
        picked, control_map = manufacture_controls(
            {r["word"].lower() for r in rows}, want, batch)
        if picked:
            rows = rows + picked
            random.Random(int(hashlib.sha256(
                (batch + 'mix').encode()).hexdigest()[:8], 16)).shuffle(rows)
            batch = f"{batch}-c{len(picked)}"
            print(f"{len(picked)} hidden controls mixed in "
                  f"({sum(1 for v in control_map.values() if v=='wrong')} broken on "
                  f"purpose, {sum(1 for v in control_map.values() if v=='right')} "
                  f"left alone) — all of them words you have never judged")
        else:
            print("could not build controls — this batch is unguarded")

    print(f"synthesizing {len(rows)} headwords through the live tts function…")

    out: list[dict] = []
    failed = 0

    def one(r: dict) -> None:
        nonlocal failed
        # The carrier is the hypothesis under test, not a cosmetic wrapper.
        # `regenerative cooling` was heard correctly while `regenerative` alone
        # was not, so context may be doing the work a hand-written phoneme would
        # otherwise have to. If a frame fixes these words, one change to
        # Voice.speak fixes every one of them at once and no ARPAbet gets
        # written by hand at all.
        # A row may carry its own synthesis text (--say), which the carrier
        # then wraps if both are in play. Controls never carry one, so they
        # are still spoken as themselves and remain valid controls.
        source = r.get("speak") or r["word"]
        spoken = args.carrier.replace("{word}", source) if args.carrier else source
        ok, url, detail = synth(base, anon, admin, spoken, args.accent)
        if not ok:
            failed += 1
            print(f"  FAILED {r['word']}: {detail}")
            return
        out.append({
            "word": r["word"],
            "spoken": spoken,
            "url": url,
            "band": r.get("difficulty", ""),
            "syllables": r.get("syllables", ""),
            "guess": r.get("espeak_untrusted_guess", ""),
            "state": detail,
        })

    # Three at a time: politeness to the Edge Function, same as warm_audio.
    with ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(one, rows))

    if not out:
        die("nothing synthesized — check the token and try one word by hand")
    out.sort(key=lambda d: [r["word"] for r in rows].index(d["word"]))
    fresh = sum(1 for d in out if d["state"] == "new")
    cached = len(out) - fresh
    print(f"  {len(out)} ready ({fresh} newly synthesized, {cached} already cached), "
          f"{failed} failed")

    # A cache hit in a non-default accent is evidence the server never heard
    # about the accent. The voice id is part of the cache key, so the first
    # batch in a new voice CANNOT hit the cache — every clip is new by
    # construction. If it does, the deployed tts function is still resolving
    # every request to the default voice and this batch is that voice wearing
    # the wrong filename.
    #
    # Caught the hard way: the first --accent uk run reported 6 of 11 cached,
    # which was the whole batch quietly being Victoria, because the accent
    # routing was written and not deployed.
    if args.accent != "us" and cached:
        print()
        print(f"  !! {cached} of {len(out)} clips came back CACHED in accent "
              f"'{args.accent}'.")
        print("     The voice id is part of the cache key, so a clip in a new")
        print("     accent cannot already exist. Either the tts function has")
        print("     not been deployed with accent routing, or it does not")
        print("     recognise this accent and fell back to the default voice.")
        print("     DO NOT judge this batch as evidence about "
              f"'{args.accent}' — it is almost certainly the default voice.")
        print("     Check: supabase functions deploy tts, then rebuild.")

    if args.carrier:
        # The FRAME goes in the name, not just the fact that there is one.
        # Naming it "-carrier" meant two different frames wrote to one file and
        # the second destroyed the first — the same collision as survey.html,
        # fixed once at the mode level and not at the level that actually
        # changes what is spoken. Anything that changes the audio belongs here.
        batch = batch + "-" + carrier_slug(args.carrier)
    if control_map:
        controls_path(batch).write_text(
            json.dumps(control_map, indent=1, sort_keys=True), encoding="utf-8")
    dest = survey_path(batch)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(render(out, batch), encoding="utf-8")
    print(f"\nwritten {dest}")
    print("Open it in a browser. Space plays, 1 = right, 2 = wrong, 3 = unsure.")
    print("It saves as you go and downloads verdicts.json at the end.")


def find_verdicts(given: str | None) -> Path:
    """Locates verdicts.json, defaulting to where a browser actually puts it.

    The download lands in the OS Downloads folder, not next to the survey, and
    the first version of this tool told you to pass a path inside the repo that
    nothing ever writes to. Look in the obvious places instead of being right
    and useless.
    """
    if given:
        p = Path(given)
        if p.exists():
            return p
        die(f"cannot find {p}")
    dirs = [PRON, Path.home() / "Downloads", Path.cwd()]
    found: list[Path] = []
    for d in dirs:
        if d.is_dir():
            # Glob, not an exact name. Batches produce verdicts-<batch>.json, and
            # a browser re-download becomes "verdicts-traps (1).json". Naming the
            # file it could not find, when a near-match sits beside it, is the
            # least useful thing an error can do.
            found += sorted(d.glob("verdicts*.json"))
    if len(found) == 1:
        print(f"using {found[0]}")
        return found[0]
    if len(found) > 1:
        die("several verdict files — say which:\n  " +
            "\n  ".join(f'python tools/pronunciation_survey.py merge "{f}"' for f in found))
    die("no verdicts file yet, and this step cannot make one.\n\n"
        "  1. open one of these in a browser:\n     " +
        "\n     ".join(str(x) for x in sorted(PRON.glob("survey-*.html"))) +
        "\n  2. listen: space plays, 1 right, 2 wrong, 3 unsure\n"
        "  3. press \"Download verdicts.json\" at the bottom\n\n"
        "Looked for verdicts*.json in:\n  " + "\n  ".join(str(d) for d in dirs))
    raise SystemExit(1)  # unreachable; keeps type checkers quiet


def cmd_merge(args: argparse.Namespace) -> None:
    """Folds a finished survey into manual_pronunciations.json as a work list."""
    p = find_verdicts(args.verdicts)
    raw = json.loads(p.read_text(encoding="utf-8"))
    if isinstance(raw, dict) and "verdicts" in raw:
        batch, offered, verdicts = raw.get("batch", "?"), raw.get("words", []), raw["verdicts"]
        # Browser storage is keyed by batch name and outlives a rebuild, so a
        # page rebuilt after the tool changed can hand back verdicts for rows
        # it no longer contains. The say-1049b4a7 download on 7 Sep carried a
        # bare "glissade" left over from the build whose five candidate rows
        # all collided on one key. Those are not judgements about this batch
        # and must not be counted in its rate or written to the ledger.
        keys = raw.get("keys")
        if keys:
            stale = {k: v for k, v in verdicts.items() if k not in set(keys)}
            if stale:
                print(f"dropping {len(stale)} verdict(s) for rows not in this "
                      f"batch (left in browser storage by an earlier build): "
                      f"{', '.join(sorted(stale))}")
                verdicts = {k: v for k, v in verdicts.items() if k in set(keys)}
    else:  # the first survey downloaded a bare map, before batches existed
        batch, offered, verdicts = "(unlabelled)", [], raw
    judged = len(verdicts)
    print(f"batch {batch}: {judged} judged"
          + (f" of {len(offered)} offered" if offered else ""))
    if offered and judged < len(offered):
        print(f"  {len(offered)-judged} unanswered — the rate below is over what "
              "you actually listened to, not the whole batch")
    # Controls first. If this batch cannot reproduce verdicts it has already
    # settled, its opinion about the other words is not worth recording.
    cpath = controls_path(batch)
    controls = {}
    if cpath.exists():
        try:
            controls = json.loads(cpath.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            controls = {}
    agree = miss = 0
    if controls:
        lines = []
        for w, expected in sorted(controls.items()):
            got = verdicts.get(w)
            if got is None:
                continue
            ok = got == expected
            agree, miss = (agree + 1, miss) if ok else (agree, miss + 1)
            if not ok:
                lines.append(f"    {w}: settled {expected}, heard {got}")
        total = agree + miss
        if total:
            print(f"controls: {agree}/{total} reproduced"
                  f"  ->  {agree/total*100:.0f}% agreement")
            for ln in lines:
                print(ln)
        if total and agree / total < CONTROL_FLOOR:
            print(f"\ncontrols below {CONTROL_FLOOR*100:.0f}% — NOT merging this batch.")
            print("The disagreement is in the listening, not the audio: control clips")
            print("are cache hits, so they are the identical bytes judged last time.")
            print("Re-listen, or discard the batch. A rate measured by an ear that")
            print("cannot reproduce itself is not a rate.")
            return

    scored = {w: v for w, v in verdicts.items() if w not in controls}
    # Respelling candidates carry a compound key (word=respelling). They are
    # judgements about a CANDIDATE, not about the catalogue word, and must not
    # reach the ledger or the work list: `glissade=glissod` is not a headword,
    # and a null entry under that name would sit in manual_pronunciations.json
    # forever waiting for a phoneme nobody can write.
    cand = {k: v for k, v in scored.items() if "=" in k}
    scored = {k: v for k, v in scored.items() if "=" not in k}
    if cand:
        print(f"\n{len(cand)} respelling candidate(s) — reported, not merged:")
        for k, v in sorted(cand.items(), key=lambda kv: (kv[0], kv[1])):
            head, _, spoken = k.partition("=")
            print(f"    {head:<16} spoken as {spoken:<16} {v}")
        winners = [k.partition("=")[2] for k, v in cand.items() if v == "right"]
        print("    winners: " + (", ".join(sorted(winners)) if winners
                                 else "none — no candidate was heard right"))
    wrong = [w for w, v in scored.items() if v == "wrong"]
    unsure = [w for w, v in scored.items() if v == "unsure"]
    right = [w for w, v in scored.items() if v == "right"]
    n = len(scored)
    print(f"excluding controls: {n} words judged")
    print(f"heard right {len(right)}, wrong {len(wrong)}, unsure {len(unsure)}"
          + (f"  ->  {len(wrong)/n*100:.1f}% wrong" if n else ""))

    # The ledger is what makes the NEXT batch measurable. Every verdict goes in,
    # not just the failures, because controls need known-good far more than they
    # need known-bad.
    led = load_ledger()
    for w, v in scored.items():
        if v not in ("right", "wrong"):
            continue
        e = led.setdefault(w, {"right": 0, "wrong": 0, "batches": []})
        e[v] = e.get(v, 0) + 1
        if batch not in e["batches"]:
            e["batches"].append(batch)
        # Settled only once the same verdict has come back twice and never
        # been contradicted. One listen is an opinion; two agreeing is a fact.
        e["settled"] = (v if e.get(v, 0) >= 2 and e.get(
            "wrong" if v == "right" else "right", 0) == 0 else None)
    save_ledger(led)
    settled = sum(1 for v in led.values() if v.get("settled"))
    print(f"ledger: {len(led)} words, {settled} settled and usable as controls")

    if not wrong:
        print("nothing to fix in this batch.")
        return
    manual = json.loads(MANUAL.read_text(encoding="utf-8")) if MANUAL.exists() else {}
    added = [w for w in wrong if w not in manual]
    for w in added:
        # Deliberately null, not a guessed phoneme. A wrong entry is worse than
        # no entry: the dictionary emits nothing at all for a malformed one.
        manual[w] = None
    MANUAL.write_text(json.dumps(manual, indent=2, sort_keys=True), encoding="utf-8")
    print(f"added {len(added)} words to {MANUAL.name} awaiting a hand-written phoneme.")
    print("Words heard wrong, in order:")
    for w in wrong:
        print(f"  {w}")


REFERENCE = PRON / "reference.json"


def load_reference() -> dict:
    """Accepted English pronunciations, keyed by word. See reference.json.

    A listener cannot judge `bigarade` against nothing. Until now the page
    asked "is that right?" about words most people have never heard said
    aloud, which quietly turned the survey into a test of how French the clip
    sounded — and for words like `persillade` and `chamois`, the more French
    it sounds the more WRONG it is.

    The reference is hidden until the verdict is in, so the judgement is still
    made cold. It is there to catch the case where you were about to be right
    for the wrong reason, not to tell you the answer in advance.
    """
    if not REFERENCE.exists():
        return {}
    try:
        return json.loads(REFERENCE.read_text(encoding="utf-8")).get("words", {})
    except (json.JSONDecodeError, OSError) as e:
        print(f"warning: reference.json unreadable ({e}); building without it")
        return {}


def render(items: list[dict], batch: str) -> str:
    # A UNIQUE key per row, because the page stores verdicts in a map and a
    # map cannot hold five answers under one name.
    #
    # 7 Sep 2026: `--say glissade=A,glissade=B,...` builds five rows all
    # LABELLED glissade — that is the whole design, the listener must not know
    # which respelling produced which clip. But the page keyed verdicts by
    # `word`, so the five rows shared one slot: judging the second overwrote
    # the first, every row lit up with the same answer, the counter still read
    # "5 of 5 judged", and the download carried a single verdict. Silent, and
    # the failure looks exactly like success.
    #
    # A word that appears once keeps its own name as the key, so every batch
    # built before today and every batch of distinct words after it is
    # byte-identical to what it was. Only a duplicated label gets a compound
    # key, and only because it has to.
    from collections import Counter
    seen = Counter(d["word"] for d in items)
    for d in items:
        d["key"] = (d["word"] if seen[d["word"]] == 1
                    else f'{d["word"]}={d.get("spoken") or d["word"]}')
    dupes = sorted({d["word"] for d in items if seen[d["word"]] > 1})
    if dupes:
        print(f"{len(dupes)} label(s) appear on more than one row and are keyed "
              f"by what was spoken: {', '.join(dupes)}")
    data = json.dumps(items)
    ref = load_reference()
    have = sum(1 for d in items if d["word"].lower() in ref)
    print(f"reference available for {have} of {len(items)} rows"
          + ("" if have else " — tools/pronunciation/reference.json is missing or empty"))
    rows = []
    for i, d in enumerate(items):
        r = ref.get(d["word"].lower())
        if r:
            bits = ["<b>" + escape(" &nbsp;or&nbsp; ".join(r["accepted"])) + "</b>"]
            if r.get("avoid"):
                bits.append("not: " + escape(r["avoid"]))
            if r.get("note"):
                bits.append(escape(r["note"]))
            body = " &middot; ".join(bits).replace("&amp;nbsp;", "&nbsp;")
        else:
            body = "<i>no reference recorded &mdash; judge on your ear alone, " \
                   "and mark unsure if you cannot</i>"
        rows.append(f'''<li class="row" data-i="{i}" id="row{i}">
  <div class="idx">{i+1}</div>
  <div class="main">
    <button class="play" data-url="{escape(d['url'])}" aria-label="Play {escape(d['word'])}">▶</button>
    <span class="w">{escape(d['word'])}</span>
    <span class="meta">{escape(d.get('spoken','') if d.get('spoken')!=d['word'] else str(d['syllables'])+' syl')} · {escape(d['band'])}</span>
  </div>
  <div class="verdicts">
    <button class="v ok"     data-v="right"  data-i="{i}">Right</button>
    <button class="v bad"    data-v="wrong"  data-i="{i}">Wrong</button>
    <button class="v meh"    data-v="unsure" data-i="{i}">Unsure</button>
  </div>
  <div class="ref" id="ref{i}" hidden>{body}</div>
</li>''')
    return (TEMPLATE.replace("__ROWS__", "\n".join(rows))
            .replace("__DATA__", data).replace("__BATCH__", batch))


TEMPLATE = r"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Qulex — pronunciation survey</title>
<style>
:root{--bg:#07070C;--surface:#0B0B12;--line:#22222E;--cream:#F2EDE4;--muted:#A6A2AE;
 --coral:#E4572E;--teal:#2FA5A0;--amber:#D9A63C}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--cream);font-size:16px;line-height:1.5;
 font-family:ui-sans-serif,-apple-system,"Segoe UI",Inter,Helvetica,Arial,sans-serif}
.wrap{max-width:900px;margin:0 auto;padding:28px 20px 120px}
.kicker{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11px;
 letter-spacing:.22em;text-transform:uppercase;color:var(--coral);margin:0 0 10px}
h1{font-family:ui-serif,Georgia,serif;font-size:28px;margin:0 0 8px;font-weight:600}
.sub{color:var(--muted);font-size:14.5px;margin:0 0 6px;max-width:64ch}
.rule{height:2px;width:56px;background:var(--coral);margin:18px 0 26px}
ul{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:2px}
.row{display:grid;grid-template-columns:34px 1fr auto;align-items:center;gap:14px;
 background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:10px 14px}
/* Dim the judged row's LABEL only. Dimming the whole row would take the
   reference down with it, and the reference is the one thing you need to be
   able to read after answering. (Opacity on the parent cannot be undone by a
   child — it makes a stacking context — so the dimming has to be applied to
   the specific children instead.) */
.row.done > .idx, .row.done > .main{opacity:.42}
.ref{grid-column:1/-1;margin:8px 0 2px;padding:8px 11px;border-left:2px solid var(--teal);
 background:rgba(47,165,160,.07);font-size:13px;color:var(--muted);line-height:1.45}
.ref b{color:var(--cream);font-family:ui-monospace,Menlo,monospace;font-size:12.5px}
.ref i{color:var(--amber);font-style:normal}
.row.cur{border-color:var(--coral);box-shadow:0 0 0 1px var(--coral)}
.idx{font-family:ui-monospace,Menlo,monospace;font-size:12px;color:var(--muted);
 font-variant-numeric:tabular-nums}
.main{display:flex;align-items:center;gap:12px;min-width:0}
.w{font-family:ui-serif,Georgia,serif;font-size:20px;overflow-wrap:anywhere}
.meta{font-family:ui-monospace,Menlo,monospace;font-size:11px;color:var(--muted);white-space:nowrap}
button{font:inherit;cursor:pointer;border-radius:8px;border:1px solid var(--line);
 background:transparent;color:var(--cream);transition:background .12s,border-color .12s}
button:focus-visible{outline:2px solid var(--coral);outline-offset:2px}
.play{width:36px;height:36px;flex:none;border-color:var(--coral);color:var(--coral);font-size:13px}
.play:hover{background:rgba(228,87,46,.14)}
.verdicts{display:flex;gap:6px}
.v{padding:7px 13px;font-size:13.5px}
.v:hover{border-color:var(--muted)}
.v.sel.ok{background:var(--teal);border-color:var(--teal);color:#04231F}
.v.sel.bad{background:var(--coral);border-color:var(--coral);color:#1A0500}
.v.sel.meh{background:var(--amber);border-color:var(--amber);color:#241A03}
.bar{position:fixed;left:0;right:0;bottom:0;background:var(--surface);
 border-top:1px solid var(--line);padding:12px 20px;display:flex;gap:18px;
 align-items:center;justify-content:center;flex-wrap:wrap}
.count{font-family:ui-monospace,Menlo,monospace;font-size:13px;color:var(--muted);
 font-variant-numeric:tabular-nums}
.count b{color:var(--cream)}
.dl{padding:9px 18px;border-color:var(--coral);color:var(--coral)}
.dl:hover{background:rgba(228,87,46,.14)}
kbd{font-family:ui-monospace,Menlo,monospace;font-size:11px;border:1px solid var(--line);
 border-radius:4px;padding:1px 5px;color:var(--muted)}
@media (prefers-reduced-motion:reduce){*{transition:none!important}}
</style></head><body>
<div class="wrap">
<p class="kicker">Qulex · pronunciation survey · batch __BATCH__</p>
<h1>Does the engine actually say these correctly?</h1>
<p class="sub">Each clip is the live app voice, fetched from the same cache a learner hears.
Speech-to-text already passed every one of these words — it can only tell that the right
word was recognised, never that it was said with the right stress. That is what your ear
is for.</p>
<p class="sub">Once you answer, the accepted English pronunciation appears under the row
where one is on record. <b>The standard is accepted English, not French</b> &mdash; several of
these have a settled English form a long way from the original, and a clip that matches it is
right. If your verdict and the reference disagree, replay the clip and change your answer;
that is what it is for.</p>
<p class="sub"><kbd>space</kbd> replay · <kbd>1</kbd> right · <kbd>2</kbd> wrong ·
<kbd>3</kbd> unsure · <kbd>↑</kbd><kbd>↓</kbd> move. Answering advances and plays the next.</p>
<div class="rule"></div>
<ul id="list">
__ROWS__
</ul>
</div>
<div class="bar">
  <span class="count"><b id="n">0</b> of <b id="tot">0</b> judged · <b id="nb">0</b> wrong</span>
  <button class="dl" id="dl">Download verdicts.json</button>
</div>
<script>
const ITEMS = __DATA__;
const BATCH = '__BATCH__';
const KEY = 'qulex-pron-' + BATCH;
let verdicts = {};
try { verdicts = JSON.parse(localStorage.getItem(KEY) || '{}'); } catch (e) { verdicts = {}; }
let cur = 0;
const audio = new Audio();

function play(i){
  const el = document.querySelector('#row'+i+' .play');
  if(!el) return;
  audio.pause();
  audio.src = el.dataset.url;
  audio.play().catch(()=>{});
}
function focusRow(i){
  document.querySelectorAll('.row.cur').forEach(r=>r.classList.remove('cur'));
  const r = document.getElementById('row'+i);
  if(!r) return;
  cur = i; r.classList.add('cur');
  r.scrollIntoView({block:'center', behavior:'smooth'});
}
function paint(){
  let done=0, bad=0;
  ITEMS.forEach((it,i)=>{
    const v = verdicts[it.key];
    const row = document.getElementById('row'+i);
    row.classList.toggle('done', !!v);
    // Revealed only once a verdict exists. Showing it earlier would make the
    // page a reading test rather than a listening one.
    const rf = document.getElementById('ref'+i);
    if(rf) rf.hidden = !v;
    row.querySelectorAll('.v').forEach(b=>b.classList.toggle('sel', b.dataset.v===v));
    if(v){ done++; if(v==='wrong') bad++; }
  });
  document.getElementById('n').textContent = done;
  document.getElementById('nb').textContent = bad;
  document.getElementById('tot').textContent = ITEMS.length;
}
function setV(i, v){
  verdicts[ITEMS[i].key] = v;
  try { localStorage.setItem(KEY, JSON.stringify(verdicts)); } catch(e){}
  paint();
  const next = i+1;
  if(next < ITEMS.length){ focusRow(next); play(next); }
}
document.querySelectorAll('.play').forEach(b=>b.addEventListener('click', e=>{
  const i = +e.target.closest('.row').dataset.i; focusRow(i); play(i);
}));
document.querySelectorAll('.v').forEach(b=>b.addEventListener('click', e=>{
  setV(+e.target.dataset.i, e.target.dataset.v);
}));
document.addEventListener('keydown', e=>{
  if(e.target.tagName === 'INPUT') return;
  if(e.key===' '){ e.preventDefault(); play(cur); }
  else if(e.key==='1'){ setV(cur,'right'); }
  else if(e.key==='2'){ setV(cur,'wrong'); }
  else if(e.key==='3'){ setV(cur,'unsure'); }
  else if(e.key==='ArrowDown'){ e.preventDefault(); if(cur+1<ITEMS.length){focusRow(cur+1);} }
  else if(e.key==='ArrowUp'){ e.preventDefault(); if(cur>0){focusRow(cur-1);} }
});
document.getElementById('dl').addEventListener('click', ()=>{
  // The batch and its word list travel WITH the verdicts. Without them a rate
  // cannot be computed honestly: you would not know which words were offered,
  // only which were answered.
  const payload = {batch: BATCH, words: ITEMS.map(i=>i.word),
                   keys: ITEMS.map(i=>i.key), verdicts: verdicts};
  const blob = new Blob([JSON.stringify(payload, null, 2)], {type:'application/json'});
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob); a.download = 'verdicts-' + BATCH + '.json'; a.click();
});
paint(); focusRow(0);
</script>
</body></html>
"""


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build", help="synthesize candidates and write the survey page")
    b.add_argument("--top", type=int, default=100,
                   help="how many of the highest-scoring words to survey (default 100)")
    b.add_argument("--words", default=None,
                   help="comma-separated words to survey instead, for testing a "
                        "hypothesis or re-checking a known failure")
    b.add_argument("--sample", type=int, default=None,
                   help="draw this many at RANDOM instead — the only mode that "
                        "measures the true rate, since ranking picks its own evidence")
    b.add_argument("--seed", type=int, default=1,
                   help="seed for --sample, so a rate can be re-measured (default 1)")
    b.add_argument("--carrier", default=None,
                   help="speak each word inside a frame, e.g. \"The word is "
                        "{word}.\" — tests whether context fixes the reading")
    b.add_argument("--controls", type=int, default=6,
                   help="upper bound on hidden controls mixed into the batch and "
                        "scored at merge (default 6, scaled down for small "
                        "batches). Never a word you have already judged or fixed")
    b.add_argument("--no-controls", action="store_true",
                   help="build without controls. The result measures the words "
                        "but not the listener; merge cannot vouch for it")
    b.add_argument("--accent", default="us", choices=("us", "uk"),
                   help="which voice speaks the batch (default us). A batch is "
                        "only evidence about the accent it was synthesized in")
    b.add_argument("--say", default=None,
                   help="verify respellings as the app speaks them: "
                        "word=respelling,word2=respelling2. The row is labelled "
                        "with the word and spoken as the respelling")
    b.add_argument("--traps", action="store_true",
                   help="only words carrying an orthographic trap (silent onset, "
                        "-ative, -atory, -ology, eu/oe/ae)")
    b.set_defaults(func=cmd_build)
    m = sub.add_parser("merge", help="fold a finished verdicts.json into the work list")
    m.add_argument("verdicts", nargs="?", default=None,
                   help="path to verdicts.json; omit to look in Downloads and "
                        "tools/pronunciation automatically")
    m.set_defaults(func=cmd_merge)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
