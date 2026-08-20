#!/usr/bin/env python3
"""Write a second example sentence, in all five languages, for every entry
that lacks one.

    export ANTHROPIC_API_KEY=sk-ant-...
    python tools/generate_examples.py plan          # what it would do, and the bill
    python tools/generate_examples.py submit        # send the batches
    python tools/generate_examples.py poll          # check on them
    python tools/generate_examples.py apply         # merge results into words.json

WHY A SECOND EXAMPLE AT ALL

Every entry already carries one example per language. A single sentence shows
you a word in one frame; two show you that the word survives a change of
context, which is most of the difference between recognising a word and knowing
it. It is also the cheapest available answer to the one thing WordUp genuinely
does better — real film and television clips per word. We cannot match the
clips. We can stop showing a single sentence and calling it context.

WHY THE BATCH API

This is 15,227 entries x 5 languages, about 76,000 sentences. On the standard
endpoint that is a long serial grind against rate limits. The Batch API takes
the whole job, runs it within 24 hours, and costs half. The entire run is a few
dollars on Haiku 4.5 — the expensive part of this feature was never the tokens,
it was believing it would be expensive and therefore not doing it.

WHAT THIS DELIBERATELY WILL NOT DO

- Touch an entry that already has a second example. Regenerating good content
  to make a script simpler is how you quietly get worse over time.
- Write the new sentences into assets/words.json without validation. Every
  returned entry is checked for all five languages, non-empty text, a sane
  length, and — the one that actually matters — that the sentence CONTAINS the
  word it is supposed to be demonstrating. A model that returns a fluent
  sentence about something else is the failure mode here, and it is invisible
  unless you look for it.
- Publish. `apply` edits the local catalogue and stops. Shipping it is
  publish_catalogue.py's job, deliberately, so the diff can be read first.
"""

import argparse
import json
import os
import pathlib
import re
import sys
import unicodedata
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORDS = ROOT / "assets" / "words.json"
STATE = ROOT / "tools" / ".example_batches.json"

API = "https://api.anthropic.com/v1"
MODEL = "claude-haiku-4-5"
LANGS = ["en", "es", "pt", "it", "fr"]
LANG_NAMES = {
    "en": "English", "es": "Spanish", "pt": "Portuguese",
    "it": "Italian", "fr": "French",
}

# Entries per request. Bigger batches amortise the system prompt but make one
# bad response cost more entries, and push the output closer to a truncation.
PER_REQUEST = 10

SYSTEM = """You write example sentences for a vocabulary-learning app.

For each entry you are given an English headword, its part of speech, its
meaning, and the example sentence the app ALREADY shows. Write ONE more example
sentence per language, in all five languages.

Rules, in order of importance:

1. The English sentence must contain the headword itself, spelled exactly as
   given (inflection is fine: "abated", "abating"). A sentence that does not
   contain the word teaches nothing.
2. The new sentence must show the word in a DIFFERENT situation from the
   existing one. If the existing example is about weather, do not write another
   about weather. This is the whole point of a second example.
3. The four translations must be natural sentences in their own language that
   convey the same situation. Translate the MEANING, not the word order. Do not
   leave the English headword sitting untranslated inside them.
4. 8 to 18 words. Everyday register. No proper nouns, no brand names, nothing
   that dates.
5. Nothing violent, sexual, medical-scare, or otherwise unpleasant to meet
   unexpectedly while studying on a bus.

Return ONLY a JSON array, one object per entry, in the order given:
[{"id": "w_x", "en": "...", "es": "...", "pt": "...", "it": "...", "fr": "..."}]
No prose, no markdown fence."""


def load_words():
    data = json.loads(WORDS.read_text(encoding="utf-8"))
    return data["words"] if isinstance(data, dict) and "words" in data else data


def needs_example(entry):
    g = entry.get("gloss") or {}
    for lang in LANGS:
        block = g.get(lang) or {}
        ex2 = block.get("example2") or {}
        if not (ex2.get("text") or "").strip():
            return True
    return False


def request_body(chunk):
    lines = []
    for e in chunk:
        en = (e["gloss"].get("en") or {})
        existing = ((en.get("example") or {}).get("text") or "").strip()
        lines.append(json.dumps({
            "id": e["id"],
            "word": e["word"],
            "pos": e["pos"],
            "meaning": en.get("correct", ""),
            "existing_example": existing,
        }, ensure_ascii=False))
    return "\n".join(lines)


def cmd_plan(args):
    words = load_words()
    todo = [e for e in words if needs_example(e)]
    n_req = (len(todo) + PER_REQUEST - 1) // PER_REQUEST
    # Measured shape: ~900 input tokens per request, ~26 output tokens per
    # sentence x 5 languages x PER_REQUEST entries.
    in_tok = n_req * 900
    out_tok = n_req * PER_REQUEST * 5 * 26
    batch_cost = in_tok / 1e6 * 0.50 + out_tok / 1e6 * 2.50
    print(f"catalogue           : {len(words):,} entries")
    print(f"already have two    : {len(words) - len(todo):,}")
    print(f"to generate         : {len(todo):,} entries x 5 languages "
          f"= {len(todo) * 5:,} sentences")
    print(f"requests            : {n_req:,} at {PER_REQUEST} entries each")
    print(f"estimated tokens    : {in_tok/1e6:.2f}M in, {out_tok/1e6:.2f}M out")
    print(f"estimated cost      : ${batch_cost:,.2f} on the Batch API "
          f"(${in_tok/1e6*1.0 + out_tok/1e6*5.0:,.2f} standard)")
    print()
    print("Estimates, not quotes. Run `submit` to start; nothing is spent until then.")


def api(path, payload=None, method="GET"):
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        sys.exit("ANTHROPIC_API_KEY is not set.")
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        f"{API}/{path}", data=data, method=method,
        headers={
            "x-api-key": key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        })
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code}: {e.read().decode()[:800]}")


def cmd_submit(args):
    words = load_words()
    todo = [e for e in words if needs_example(e)]
    if args.limit:
        todo = todo[: args.limit]
    if not todo:
        print("Nothing to do — every entry already has a second example.")
        return

    chunks = [todo[i:i + PER_REQUEST] for i in range(0, len(todo), PER_REQUEST)]
    # The Batch API caps a batch; several batches is fine and they run in
    # parallel.
    PER_BATCH = 2000
    batches = [chunks[i:i + PER_BATCH] for i in range(0, len(chunks), PER_BATCH)]

    ids = []
    for bi, group in enumerate(batches):
        requests = []
        for ci, chunk in enumerate(group):
            requests.append({
                "custom_id": f"b{bi}-c{ci}",
                "params": {
                    "model": MODEL,
                    "max_tokens": 4000,
                    "system": SYSTEM,
                    "messages": [{"role": "user", "content": request_body(chunk)}],
                },
            })
        res = api("messages/batches", {"requests": requests}, "POST")
        ids.append({"id": res["id"], "chunks": [[e["id"] for e in c] for c in group]})
        print(f"batch {bi + 1}/{len(batches)} submitted: {res['id']} "
              f"({len(requests)} requests)")

    STATE.write_text(json.dumps({"batches": ids}, indent=1), encoding="utf-8")
    print(f"\nState written to {STATE.relative_to(ROOT)}. Run `poll` in a while.")


def cmd_poll(args):
    if not STATE.exists():
        sys.exit("No batches in flight — run `submit` first.")
    state = json.loads(STATE.read_text())
    done = 0
    for b in state["batches"]:
        res = api(f"messages/batches/{b['id']}")
        counts = res.get("request_counts", {})
        status = res.get("processing_status")
        print(f"{b['id']}: {status}  {counts}")
        if status == "ended":
            done += 1
    print(f"\n{done}/{len(state['batches'])} batches finished.")
    if done == len(state["batches"]):
        print("Run `apply` to merge the results in.")


WORD_RE = re.compile(r"[^\W\d_]+", re.UNICODE)


# Irregular English verbs whose past forms share no usable prefix with the
# infinitive. Without this table the check rejects "She caught the ball" as
# evidence for `catch` — and it did, for all 22 irregular verbs in the shipped
# catalogue, which are also among the commonest words in the language.
IRREGULAR = {
    "be": "was were been am is are", "bear": "bore borne",
    "beat": "beat beaten", "become": "became", "begin": "began begun",
    "bend": "bent", "bind": "bound", "bite": "bit bitten",
    "bleed": "bled", "blow": "blew blown", "break": "broke broken",
    "breed": "bred", "bring": "brought", "build": "built",
    "buy": "bought", "catch": "caught", "choose": "chose chosen",
    "cling": "clung", "come": "came", "creep": "crept", "deal": "dealt",
    "dig": "dug", "do": "did done does", "draw": "drew drawn",
    "drink": "drank drunk", "drive": "drove driven", "eat": "ate eaten",
    "fall": "fell fallen", "feed": "fed", "feel": "felt", "fight": "fought",
    "find": "found", "flee": "fled", "fling": "flung", "fly": "flew flown",
    "forbid": "forbade forbidden", "forget": "forgot forgotten",
    "forgive": "forgave forgiven", "freeze": "froze frozen",
    "get": "got gotten", "give": "gave given", "go": "went gone goes",
    "grind": "ground", "grow": "grew grown", "hang": "hung",
    "have": "had has", "hear": "heard", "hide": "hid hidden",
    "hold": "held", "keep": "kept", "kneel": "knelt", "know": "knew known",
    "lay": "laid", "lead": "led", "leave": "left", "lend": "lent",
    "lie": "lay lain", "lose": "lost", "make": "made", "mean": "meant",
    "meet": "met", "pay": "paid", "ride": "rode ridden", "ring": "rang rung",
    "rise": "rose risen", "run": "ran", "say": "said", "see": "saw seen",
    "seek": "sought", "sell": "sold", "send": "sent", "shake": "shook shaken",
    "shine": "shone", "shoot": "shot", "show": "showed shown",
    "shrink": "shrank shrunk", "sing": "sang sung", "sink": "sank sunk",
    "sit": "sat", "sleep": "slept", "slide": "slid", "sling": "slung",
    "speak": "spoke spoken", "speed": "sped", "spend": "spent",
    "spin": "spun", "spit": "spat", "spring": "sprang sprung",
    "stand": "stood", "steal": "stole stolen", "stick": "stuck",
    "sting": "stung", "stink": "stank stunk", "stride": "strode stridden",
    "strike": "struck", "string": "strung", "strive": "strove striven",
    "swear": "swore sworn", "sweep": "swept", "swim": "swam swum",
    "swing": "swung", "take": "took taken", "teach": "taught",
    "tear": "tore torn", "tell": "told", "think": "thought",
    "throw": "threw thrown", "tread": "trod trodden",
    "understand": "understood", "wake": "woke woken", "wear": "wore worn",
    "weave": "wove woven", "weep": "wept", "win": "won", "wind": "wound",
    "wring": "wrung", "write": "wrote written",
}
# Prefixed forms inherit their base verb's irregularity: undo/undid,
# rewind/rewound, overcome/overcame, withhold/withheld.
_PREFIXES = ("un", "re", "over", "under", "out", "with", "fore", "mis", "pre")

# Irregular plurals, for the same reason as the verb table: `tube foot` is
# demonstrated by "hundreds of tube feet" and nothing else will match it.
IRREGULAR_PLURAL = {
    "foot": "feet", "tooth": "teeth", "goose": "geese", "man": "men",
    "woman": "women", "child": "children", "person": "people",
    "mouse": "mice", "louse": "lice", "ox": "oxen", "die": "dice",
    "datum": "data", "medium": "media", "criterion": "criteria",
    "phenomenon": "phenomena", "index": "indices", "matrix": "matrices",
    "vertex": "vertices", "axis": "axes", "crisis": "crises",
    "thesis": "theses", "analysis": "analyses", "basis": "bases",
    "fungus": "fungi", "cactus": "cacti", "nucleus": "nuclei",
    "radius": "radii", "stimulus": "stimuli", "alumnus": "alumni",
    "larva": "larvae", "vertebra": "vertebrae", "ascus": "asci",
    "sestertius": "sesterces", "ocellus": "ocelli", "bacterium": "bacteria",
}
IRREGULAR["heave"] = "hove"  # nautical, and the catalogue uses it


def _fold(t):
    """Strip accents.

    The catalogue stores loanwords unaccented — `pave`, `negociant`, `saignee`,
    `bidonvide` — while a well-written sentence spells them properly: pavé,
    négociant, saignée, bidons vides. Comparing folded forms is the difference
    between accepting those and throwing them away.
    """
    return "".join(c for c in unicodedata.normalize("NFD", t)
                   if unicodedata.category(c) != "Mn")


def _irregular_forms(stem):
    if stem in IRREGULAR:
        return set(IRREGULAR[stem].split())
    for pre in _PREFIXES:
        if stem.startswith(pre) and stem[len(pre):] in IRREGULAR:
            return {pre + f for f in IRREGULAR[stem[len(pre):]].split()}
    return set()


def sentence_uses_word(sentence, word):
    """True if the sentence actually contains the headword.

    This is the only check standing between the catalogue and a fluent sentence
    about something else, so it has to be strict. It also has to survive the
    three ways a correct sentence legitimately fails a naive match, all three of
    which the shipped catalogue demonstrates:

      * IRREGULAR INFLECTION. "She caught the ball" is `catch`. No amount of
        prefix matching finds that; it needs the table above.
      * COMPOUND HEADWORDS. The catalogue stores `bottombracket`, `waikru`,
        `halfguard` — closed up — while the sentence writes "bottom bracket",
        "wai kru", "half guard". Matched by requiring every part of the split
        headword to appear, which is stricter than the single-token rule it
        replaces, not looser.
      * DERIVATION AND SI PREFIXES. `smelting`/"smelts", `compaction`/
        "compacted", `linearizability`/"linearizable", `sievert`/
        "millisievert", `becquerel`/"megabecquerels". Handled by a shared-stem
        comparison after light suffix stripping, plus a substring check so an
        SI prefix does not hide the unit.

    Tuned against the whole shipped catalogue in both directions — see
    test_sentence_uses_word() below, which measures the false-accept rate on
    deliberately mismatched pairs rather than trusting the rule by eye.
    """
    head = WORD_RE.findall(word.lower())
    if not head:
        return True
    head = [_fold(h) for h in head]
    tokens = [_fold(t) for t in WORD_RE.findall(sentence.lower())]
    if not tokens:
        return False
    token_set = set(tokens)

    # A headword the catalogue stores closed up — `halflife`, `feedzone`,
    # `apriori`, `halfguard` — is written open in the sentence. Joining
    # adjacent tokens recovers it exactly, without loosening anything: the
    # whole headword still has to be there, just spelled across a space.
    joined = set()
    for i in range(len(tokens) - 1):
        joined.add(tokens[i] + tokens[i + 1])
        if i + 2 < len(tokens):
            joined.add(tokens[i] + tokens[i + 1] + tokens[i + 2])

    def matches(stem):
        if stem in token_set or stem in joined:
            return True
        if _irregular_forms(stem) & token_set:
            return True
        if IRREGULAR_PLURAL.get(stem) in token_set:
            return True
        # A final -y becomes -i under inflection: pry/pried, deny/denied.
        if stem.endswith("y") and any(
                t.startswith(stem[:-1] + "i") for t in tokens):
            return True
        core = _strip_suffix(stem)
        # Long enough to be distinctive; short enough to survive derivation.
        n = max(4, min(len(core), 6))
        key = core[:n]
        for t in list(tokens) + sorted(joined):
            tc = _strip_suffix(t)
            if tc.startswith(key) or key.startswith(tc[:n]) and len(tc) >= n:
                return True
            # An SI or size prefix in front of the unit: millisievert, megabecquerel.
            # An SI or size prefix in front of the unit: millisievert,
            # megabecquerel, milligray. The whole stem has to be in there for a
            # short unit like `gray` — dropping the final letter first, as the
            # longer units need for their plurals, leaves only three characters
            # and matches half the dictionary.
            if len(stem) >= 4 and stem in t:
                return True
            if len(stem) >= 6 and stem[:-1] in t:
                return True
        return False

    # A headword written closed-up ("bottombracket") is matched by requiring
    # each of its parts, which is why this splits on more than whitespace.
    parts = [_fold(p) for p in re.split(r"[\s\-']+", word.lower()) if p]
    if len(parts) > 1:
        return all(matches(p) for p in parts)
    return matches(head[0])


_SUFFIXES = ("ingly", "edly", "ations", "ation", "ising", "izing", "ised",
             "ized", "ises", "izes", "ise", "ize", "ability", "ible", "able",
             "ments", "ment", "ness", "ing", "ies", "ied", "ers", "er",
             "est", "ed", "es", "s", "y")


def _strip_suffix(t):
    for suf in _SUFFIXES:
        if len(t) - len(suf) >= 4 and t.endswith(suf):
            return t[: -len(suf)]
    return t


# Spanish verbs that are ordinary in Spain and vulgar across much of Latin
# America. `coger` is the one that actually turns up: "coger el autobús" is
# unremarkable in Madrid and obscene in Mexico City, Buenos Aires, Santiago,
# Montevideo and Caracas. The trial run produced exactly this sentence for
# `catch`, which is how the check got written.
#
# Matched on the conjugated stem with a word boundary so `cogeneración`,
# `cogestión` and friends do not trip it. Deliberately NOT a substitution:
# rewriting someone else's sentence to `tomar` is right for transport and wrong
# for other senses, and losing one entry out of thousands is cheaper than
# shipping a guess.
ES_REGIONAL = re.compile(
    # NOTE the absences. `coja` and `cojas` are subjunctive forms of coger, and
    # they are also the feminine adjective "cojo/coja" (lame, wobbly) — which is
    # what "la pata coja" in the shipped `shim` example actually is. The
    # adjective is far commoner than the subjunctive, so including those forms
    # costs more in false positives than it buys. Same reasoning excludes
    # `cogido`, which is ordinary as a past participle in Spain.
    r"\b(coger|coges|coge|cogemos|cogéis|cogen|cogí|cogiste|cogió|cogimos|"
    r"cogieron|cogeré|cogerás|cogerá|cogería|cogiendo)\b",
    re.IGNORECASE)

# Legitimate but worth knowing about: `concha` is the correct word for a shell
# and also strongly vulgar in the Southern Cone. Reported, never rejected —
# there is no other word for the shell of a mollusc, and the catalogue already
# ships seven of these.
ES_NOTE = re.compile(r"\bconchas?\b", re.IGNORECASE)


def validate(entry_by_id, obj, problems):
    wid = obj.get("id")
    src = entry_by_id.get(wid)
    if src is None:
        problems["unknown id"] += 1
        return None
    out = {}
    for lang in LANGS:
        text = (obj.get(lang) or "").strip()
        if not text:
            problems[f"missing {lang}"] += 1
            return None
        if not (20 <= len(text) <= 220):
            problems[f"length {lang}"] += 1
            return None
        existing = ((src["gloss"].get(lang) or {}).get("example") or {}).get("text", "")
        if text.strip().lower() == existing.strip().lower():
            problems[f"duplicate of existing {lang}"] += 1
            return None
        out[lang] = text
    # The check that actually catches bad generations: a fluent English
    # sentence that never mentions the word it is demonstrating.
    if not sentence_uses_word(out["en"], src["word"]):
        problems["english does not contain the headword"] += 1
        return None
    if ES_REGIONAL.search(out["es"]):
        problems["spanish uses coger (vulgar in much of Latin America)"] += 1
        return None
    if ES_NOTE.search(out["es"]):
        problems["NOTE: spanish uses concha - correct, but vulgar in the "
                 "Southern Cone; not rejected"] += 1
    return out


def cmd_apply(args):
    import collections
    if not STATE.exists():
        sys.exit("No batches recorded — run `submit` first.")
    state = json.loads(STATE.read_text())
    words = load_words()
    by_id = {e["id"]: e for e in words}

    accepted, problems = {}, collections.Counter()
    for b in state["batches"]:
        res = api(f"messages/batches/{b['id']}")
        if res.get("processing_status") != "ended":
            sys.exit(f"{b['id']} is still {res.get('processing_status')} — poll first.")
        url = res.get("results_url")
        key = os.environ["ANTHROPIC_API_KEY"]
        req = urllib.request.Request(url, headers={
            "x-api-key": key, "anthropic-version": "2023-06-01"})
        with urllib.request.urlopen(req, timeout=300) as r:
            body = r.read().decode()
        for line in body.splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            result = row.get("result", {})
            if result.get("type") != "succeeded":
                problems["request failed"] += 1
                continue
            text = "".join(
                c.get("text", "")
                for c in result["message"]["content"] if c.get("type") == "text")
            text = text.strip().removeprefix("```json").removeprefix("```").removesuffix("```")
            try:
                items = json.loads(text)
            except json.JSONDecodeError:
                problems["unparseable response"] += 1
                continue
            for obj in items if isinstance(items, list) else []:
                got = validate(by_id, obj, problems)
                if got:
                    accepted[obj["id"]] = got

    print(f"accepted {len(accepted):,} entries")
    if problems:
        print("rejected:")
        for k, v in problems.most_common():
            print(f"  {v:>6,}  {k}")

    # The counts above say the generations are WELL FORMED. They say nothing
    # about whether the sentences are any good — validate() checks that the
    # word is present, the length is sane and the JSON parses, and a bland or
    # circular sentence passes all three. Before spending on 15,227 entries,
    # read a dozen.
    if args.sample:
        import random
        rng = random.Random(11)  # fixed, so two runs show the same sample
        picks = rng.sample(sorted(accepted), min(args.sample, len(accepted)))
        print(f"\n--- {len(picks)} accepted at random ---")
        for wid in picks:
            src = by_id[wid]
            print(f"\n{src['word']}  ({src['pos']})")
            print(f"  have: {((src['gloss']['en'] or {}).get('example') or {}).get('text','')}")
            print(f"  new : {accepted[wid]['en']}")
            for lang in ("es", "fr"):
                print(f"  {lang}  : {accepted[wid][lang]}")

    if args.dry_run:
        print("\n--dry-run: assets/words.json not touched.")
        return

    for wid, langs in accepted.items():
        for lang, text in langs.items():
            block = by_id[wid]["gloss"].setdefault(lang, {})
            block["example2"] = {"text": text, "source": "generated",
                                 "attribution": None}

    WORDS.write_text(json.dumps(words, ensure_ascii=False), encoding="utf-8")
    total = sum(1 for e in words if not needs_example(e))
    print(f"\nwrote {WORDS.relative_to(ROOT)}")
    print(f"entries with a second example: {total:,} / {len(words):,} "
          f"({total / len(words):.0%})")
    print("\nNext: bump kBundledCatalogueGeneration, commit, then "
          "python tools/publish_catalogue.py publish")


def cmd_selftest(args):
    """Measure the headword check against the whole shipped catalogue.

    This exists because the check was tuned, and a tuned rule that nobody
    measures is a guess. It scores both directions:

      * FALSE REJECT — a real (word, its own sentence) pair marked as a miss.
        Every one of these is a good sentence thrown away. The first version of
        this check scored 88, all of them irregular verbs, closed-up compounds
        or SI-prefixed units.
      * FALSE ACCEPT — a sentence paired with a DIFFERENT random headword and
        marked as a match. Every one of these is a sentence about something
        else getting into the catalogue, which is the failure the check exists
        to stop.

    Random pairing overstates false accepts a little: sometimes the other word
    genuinely does appear. Treat it as an upper bound.
    """
    import random
    words = load_words()
    pairs = [(e["word"], t) for e in words for f in ("example", "example2")
             for t in [(((e["gloss"].get("en") or {}).get(f) or {}) or {})
                       .get("text") or ""] if t]
    rejected = [(a, b) for a, b in pairs if not sentence_uses_word(b, a)]
    print(f"pairs              : {len(pairs):,}")
    print(f"wrongly rejected   : {len(rejected)}  "
          f"({len(rejected) / len(pairs):.3%})")
    for a, b in rejected[: args.show]:
        print(f"    {a:<22} {b[:70]}")

    rng = random.Random(7)
    pool = [a for a, _ in pairs]
    accepted = total = 0
    for a, b in pairs:
        other = rng.choice(pool)
        if other == a:
            continue
        total += 1
        if sentence_uses_word(b, other):
            accepted += 1
    print(f"\nmismatched pairs   : {total:,}")
    print(f"wrongly accepted   : {accepted}  ({accepted / total:.3%})")
    if len(rejected) / len(pairs) > 0.005 or accepted / total > 0.005:
        sys.exit("regression: the check has drifted past half a percent")
    print("\nboth error rates under 0.5%")


def cmd_lint(args):
    """Scan the SHIPPED catalogue for the same problems validate() rejects.

    The generator only ever sees what it generates. This points the identical
    checks at assets/words.json, because the trial run made it obvious the
    catalogue was written under the same assumptions and nobody had looked.
    """
    import collections
    words = load_words()
    found = collections.defaultdict(list)
    for e in words:
        for field in ("example", "example2"):
            es = (((e["gloss"].get("es") or {}).get(field) or {}) or {}).get("text") or ""
            if es and ES_REGIONAL.search(es):
                found["spanish uses coger"].append((e["id"], e["word"], es))
            if es and ES_NOTE.search(es):
                found["spanish uses concha (correct, but vulgar in the "
                      "Southern Cone)"].append((e["id"], e["word"], es))
            en = (((e["gloss"].get("en") or {}).get(field) or {}) or {}).get("text") or ""
            if en and not sentence_uses_word(en, e["word"]):
                found["english does not contain the headword"].append(
                    (e["id"], e["word"], en))

    if not found:
        print("catalogue clean")
        return
    for label, rows in sorted(found.items()):
        print(f"\n{len(rows):,}  {label}")
        for wid, word, text in rows[:args.show]:
            print(f"     {word}  ({wid})")
            print(f"       {text}")
        if len(rows) > args.show:
            print(f"     ... and {len(rows) - args.show:,} more")
    print("\nReported, not fixed. Rewriting someone else's sentence is a "
          "judgement call, and there are few enough to do by hand.")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan")
    s = sub.add_parser("submit")
    s.add_argument("--limit", type=int, help="only the first N entries (a trial run)")
    sub.add_parser("poll")
    a = sub.add_parser("apply")
    a.add_argument("--sample", type=int, default=0, metavar="N",
                   help="print N accepted generations so you can read them "
                        "before trusting the acceptance count")
    st = sub.add_parser("selftest")
    st.add_argument("--show", type=int, default=10, metavar="N")
    li = sub.add_parser("lint")
    li.add_argument("--show", type=int, default=6, metavar="N",
                    help="how many offending sentences to print per category")
    a.add_argument("--dry-run", action="store_true",
                   help="report what would be accepted without writing")
    args = ap.parse_args()
    {"plan": cmd_plan, "submit": cmd_submit,
     "poll": cmd_poll, "apply": cmd_apply, "lint": cmd_lint,
     "selftest": cmd_selftest}[args.cmd](args)


if __name__ == "__main__":
    main()
