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
  // The default is the word itself — i.e. leave it alone. English has no
  // reliable respelling for the /kloʊs/ "near" reading: the -ose spelling is
  // /oʊs/ in "dose" and "gross" but /ɒs/ in "loss", so anything invented here
  // is a coin flip. The previous values were 'klohss' and 'klohz', which are
  // dictionary notation rather than English, and a neural voice read them as
  // the nonsense tokens they are — reported 21 Aug 2026 as "close" being
  // spoken "clause". 'cloze' is a real English word (the cloze test) and is
  // unambiguously /kloʊz/.
  'close': const _Heteronym('close', {'verb': 'cloze'}),
  'minute': const _Heteronym('minit', {'adjective': 'mynoot'}),
};

final RegExp _wordBoundary = RegExp(r'\b[A-Za-z]+\b');

/// True when [word] has more than one accepted reading in English.
///
/// Used by the pronunciation practice screen to be honest with the learner:
/// speech recognition returns orthography, so both readings of "wind" come
/// back as the same transcript. We can confirm the word was recognized, but
/// we cannot confirm which reading was spoken — and a teaching app should say
/// so rather than award full marks it hasn't earned.
bool isHeteronym(String word) => _heteronyms.containsKey(word.toLowerCase());

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
/// Non-headword tokens are left exactly as written. We do not know their
/// sense, and the model reading the sentence has more context than we do —
/// see the note inside the function.
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

    // ONLY THE HEADWORD IS EVER RESPELLED.
    //
    // A heteronym occurring elsewhere in a definition or example sentence has
    // a sense we do not know, and the generic default was a fixed guess that
    // is wrong about as often as it is right: "he read the book" became
    // "reed", "the bow of the ship" became "beau", "a lead pipe" became
    // "leed", and every one of the 71 English texts containing "close" got the
    // "near" reading whether or not it was a verb. 328 texts in the catalogue
    // were being rewritten this way.
    //
    // The premise at the top of this file — that the engine "picks one fixed
    // reading with no notion of context" — was true of the engines it was
    // written for. It is not true of the model Qulex actually calls, which
    // reads a whole sentence and disambiguates heteronyms from context. So
    // substituting inside a sentence now DESTROYS the information the model
    // would have used and replaces it with our guess. Confirmed by listening
    // to both versions of the same seven sentences on 21 Aug 2026.
    //
    // The headword is different, and still worth respelling: it is frequently
    // spoken alone, where there is no context to disambiguate from, and it is
    // the one token whose sense we genuinely know — from the catalogue row's
    // own `say` field, or from its part of speech.
    if (!isHead) return token;

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
