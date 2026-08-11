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

final Map<String, _Heteronym> _heteronyms = {
  'wind': const _Heteronym('winned', {'verb': 'wined'}),
  'wound': const _Heteronym('woond', {'verb': 'wownd'}),
  'read': const _Heteronym('reed', {'past': 'red'}),
  'lead': const _Heteronym('leed', {'noun': 'led'}),
  'bow': const _Heteronym('beau', {'verb': 'bough'}),
  'tear': const _Heteronym('tier', {'verb': 'tare'}),
  'close': const _Heteronym('klohss', {'verb': 'klohz'}),
  'minute': const _Heteronym('minit', {'adjective': 'mynoot'}),
};

final RegExp _wordBoundary = RegExp(r'\b[A-Za-z]+\b');

/// Rewrites [text] for the TTS engine only, substituting any known heteronym
/// with a trick-spelling. When [headword]/[headwordPos] identify the exact
/// catalogued word being spoken (its own `pos` field), that word's specific
/// sense wins over the generic default wherever it appears in [text].
String ttsRespell(String text, {String? headword, String? headwordPos}) {
  final head = headword?.toLowerCase();
  final headPos = headwordPos?.toLowerCase();
  return text.replaceAllMapped(_wordBoundary, (m) {
    final token = m.group(0)!;
    final lower = token.toLowerCase();
    final h = _heteronyms[lower];
    if (h == null) return token;
    String respelled = h.dflt;
    if (head == lower && headPos != null && h.byPos.containsKey(headPos)) {
      respelled = h.byPos[headPos]!;
    }
    // Preserve simple capitalization (sentence-initial word, etc.).
    if (token[0] == token[0].toUpperCase() && token[0] != token[0].toLowerCase()) {
      respelled = respelled[0].toUpperCase() + respelled.substring(1);
    }
    return respelled;
  });
}
