/// Best-effort fixes for English heteronyms — words spelled identically but
/// pronounced differently by meaning/part of speech (e.g. "wind" the air vs.
/// "wind" the verb to coil). Generic TTS engines pick one fixed reading with
/// no notion of context, which is exactly the reported bug: "wind" in a
/// sailing phrase read with the wrong vowel.
///
/// There's no per-request phoneme control in the TTS API we call (ElevenLabs'
/// pronunciation dictionaries are exact-string-match with no part-of-speech
/// scoping, so a single shared dictionary can't hold two different readings
/// of the same spelling — see their docs). Instead we respell the
/// *audio-only* text sent to the TTS engine, substituting a real (or clearly
/// unambiguous) English spelling that reliably steers the correct vowel —
/// e.g. "wind" (air) becomes "winned" (rhymes with sinned/pinned), "wind"
/// (to coil) becomes "wined" (rhymes with fined/lined). The text shown on
/// screen is never touched, only what we hand to the speech engine.
///
/// Scope: this covers common vowel-changing heteronyms where a reliable
/// respelling exists. Stress-shift pairs (e.g. noun REcord vs verb reCORD)
/// are a different, harder problem — plain respelling can't encode stress —
/// and aren't covered here.
class _Heteronym {
  final String dflt;
  final Map<String, String> byPos;
  const _Heteronym(this.dflt, [this.byPos = const {}]);
}

// Part of speech is only ever a *proxy* for word sense, and for several pairs
// it is a bad one: both readings share a POS, so a byPos rule there produces
// a confident wrong answer rather than a miss. Those entries now carry a
// default only, and the specific sense is supplied per-catalogue-entry via
// `Word.say`, which always wins — see [ttsRespell].
//
//   lead  - the metal AND "take the lead" / a sales lead are all nouns. The
//           old noun->'led' rule mispronounced the live entry w_lead
//           ("identified potential sales contact", said "leed") as the metal
//           on every single play.
//   wound - "an injury" (noun) and "the soldier was wounded" (verb) are both
//           said "woond"; only the past tense of *wind* is "wownd". The old
//           verb->'wownd' rule broke the far commoner verb.
//   read  - 'past' was never a value in our POS vocabulary (noun / verb /
//           adjective / adverb only), so that rule could never fire at all.
//
// The verb rules that remain are safe: to wind, to bow, to tear and to close
// each have one dominant reading. The noun-side ambiguity of bow and tear is
// not expressible here, and is left to the per-entry override.
final Map<String, _Heteronym> _heteronyms = {
  'wind': const _Heteronym('winned', {'verb': 'wined'}),
  'wound': const _Heteronym('woond'),
  'read': const _Heteronym('reed'),
  'lead': const _Heteronym('leed'),
  'bow': const _Heteronym('beau', {'verb': 'bough'}),
  'tear': const _Heteronym('tier', {'verb': 'tare'}),
  'close': const _Heteronym('klohss', {'verb': 'klohz'}),
  'minute': const _Heteronym('minit', {'adjective': 'mynoot'}),
};

final RegExp _wordBoundary = RegExp(r'\b[A-Za-z]+\b');

/// Rewrites [text] for the TTS engine only, substituting any known heteronym
/// with a trick-spelling.
///
/// Resolution order for the headword, most specific first:
///  1. [headwordSay] — the catalogue entry's own `say` field. A row in the
///     word library IS one specific sense (w_lead is the sales lead, never
///     the metal), so it knows its own reading better than anything we can
///     infer from spelling plus POS. This wins outright, and works for words
///     that aren't in the table above at all.
///  2. [headwordPos] — a byPos rule, where POS reliably picks the sense.
///  3. The generic default for that spelling.
///
/// Non-headword tokens (heteronyms occurring inside a definition or example
/// sentence) can only ever use 2 or 3 — we don't know their sense.
String ttsRespell(
  String text, {
  String? headword,
  String? headwordPos,
  String? headwordSay,
}) {
  final head = headword?.toLowerCase();
  final headPos = headwordPos?.toLowerCase();
  return text.replaceAllMapped(_wordBoundary, (m) {
    final token = m.group(0)!;
    final lower = token.toLowerCase();
    final isHead = head != null && head == lower;

    String respelled;
    if (isHead && headwordSay != null && headwordSay.isNotEmpty) {
      respelled = headwordSay;
    } else {
      final h = _heteronyms[lower];
      if (h == null) return token;
      respelled = h.dflt;
      if (isHead && headPos != null && h.byPos.containsKey(headPos)) {
        respelled = h.byPos[headPos]!;
      }
    }

    // Preserve simple capitalization (sentence-initial word, etc.).
    if (token[0] == token[0].toUpperCase() && token[0] != token[0].toLowerCase()) {
      respelled = respelled[0].toUpperCase() + respelled.substring(1);
    }
    return respelled;
  });
}
