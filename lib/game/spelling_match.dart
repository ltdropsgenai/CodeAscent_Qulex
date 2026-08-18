/// Comparison rules for Spelling mode answers.
///
/// Kept separate from the game controller so the matching rules can be tested
/// directly, and because "what counts as the same spelling" is a judgement
/// about the learner, not about game state.

/// Lowercase accented Latin letters mapped to their unaccented equivalents.
///
/// Deliberately a literal table rather than a Unicode-normalization package:
/// the catalogue is Latin-script only, and the base app keeps zero
/// third-party runtime dependencies.
const Map<String, String> _diacriticFolds = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a',
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
  'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o',
  'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u',
  'ý': 'y', 'ÿ': 'y',
  'ñ': 'n', 'ç': 'c',
  'æ': 'ae', 'œ': 'oe', 'ß': 'ss',
};

/// Replaces accented Latin letters with their plain equivalents.
String foldDiacritics(String s) {
  final out = StringBuffer();
  for (final ch in s.split('')) {
    out.write(_diacriticFolds[ch] ?? ch);
  }
  return out.toString();
}

/// Normalizes a Spelling-mode answer for comparison.
///
/// Diacritics are folded away on purpose. 77 headwords in the catalogue carry
/// accents — sauté, entrée, développé, fougère, and most of the ballet
/// vocabulary — and on a phone keyboard typing "é" means long-pressing a key
/// and choosing from a popup. Marking "saute" wrong for "sauté" tests keyboard
/// dexterity rather than spelling, so both are accepted. The reveal still
/// shows the properly accented form, which is where the learner actually sees
/// the correct spelling.
///
/// Internal whitespace is collapsed too, so "grand jete" matches
/// "grand  jeté" — several catalogue entries are two words.
String normalizeSpelling(String s) =>
    foldDiacritics(s.trim().toLowerCase()).replaceAll(RegExp(r'\s+'), ' ');
