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


def sentence_uses_word(sentence, word):
    """True if the sentence actually contains the headword.

    Prefix match on the token, so ordinary inflection passes ("abate" ->
    "abated") while an unrelated word that merely starts the same way is
    unlikely to. Multi-word headwords only need their first token.
    """
    head = WORD_RE.findall(word.lower())
    if not head:
        return True
    stem = head[0]
    check = stem[: max(4, len(stem) - 2)]
    return any(t.startswith(check) for t in WORD_RE.findall(sentence.lower()))


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


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan")
    s = sub.add_parser("submit")
    s.add_argument("--limit", type=int, help="only the first N entries (a trial run)")
    sub.add_parser("poll")
    a = sub.add_parser("apply")
    a.add_argument("--dry-run", action="store_true",
                   help="report what would be accepted without writing")
    args = ap.parse_args()
    {"plan": cmd_plan, "submit": cmd_submit,
     "poll": cmd_poll, "apply": cmd_apply}[args.cmd](args)


if __name__ == "__main__":
    main()
