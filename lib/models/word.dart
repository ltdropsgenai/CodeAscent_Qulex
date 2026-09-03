/// A per-language meaning of a word: the correct definition, two distractors,
/// and one or two example sentences — all in one language.
class Gloss {
  final String correct;
  final List<String> distractors;
  final String example;

  /// A second, distinct example sentence giving another context/usage —
  /// content-richness pass, not yet backfilled for every word, so this is
  /// null wherever it hasn't been generated yet. UI should treat it as
  /// optional bonus context, not something every word is guaranteed to have.
  final String? example2;

  /// A sentence somebody actually wrote, rather than one generated for
  /// teaching. English only, on purpose: [example] and [example2] are a
  /// parallel translation set across all five languages, and swapping one
  /// side of that pair would put a mismatched sentence under the English —
  /// the exact fault this app shipped in August. A citation is a different
  /// thing from a teaching example, so it sits beside them and is never
  /// translated. Null for words no corpus attests, which is most of the
  /// hard tail.
  final String? attested;

  /// Licence and source line for [attested]. Required whenever [attested] is
  /// set — the corpus is CC-BY and attribution is a condition of use, not a
  /// nicety, so the two fields travel together or not at all.
  final String? attestedCredit;

  const Gloss({
    required this.correct,
    required this.distractors,
    required this.example,
    this.example2,
    this.attested,
    this.attestedCredit,
  }) : assert(attested == null || attestedCredit != null,
            'an attested sentence must carry its attribution');

  factory Gloss.fromJson(Map<String, dynamic> j) => Gloss(
        correct: j['correct'] as String,
        distractors:
            (j['distractors'] as List).map((e) => e as String).toList(),
        example: ((j['example'] as Map<String, dynamic>)['text']) as String,
        example2: (j['example2'] as Map<String, dynamic>?)?['text'] as String?,
        attested: (j['attested'] as Map<String, dynamic>?)?['text'] as String?,
        attestedCredit:
            (j['attested'] as Map<String, dynamic>?)?['attribution'] as String?,
      );

  /// Correct answer + distractors, shuffled for display.
  List<String> shuffledOptions() {
    final opts = <String>[correct, ...distractors];
    opts.shuffle();
    return opts;
  }
}

/// A vocabulary item. `lang` is the language of the WORD being learned;
/// `gloss` holds its meaning in each supported UI/native language.
class Word {
  final String id;
  final String lang;
  final String word;
  final String pos;

  /// Optional TTS-only respelling for THIS entry's specific sense.
  ///
  /// A catalogue row is one meaning, so it can state its own pronunciation
  /// directly instead of us inferring it from spelling + POS at runtime.
  /// That inference is unsound for heteronyms whose readings share a part of
  /// speech (the metal "lead" and a sales "lead" are both nouns), so this
  /// field is the authoritative answer where it's set. Null for the vast
  /// majority of words, which need no help.
  ///
  /// Audio only — never shown on screen. Today it holds a trick-spelling
  /// ("leed", "wined"); when a model with per-request phoneme control lands
  /// it can hold IPA instead, without touching call sites.
  ///
  /// WRITING ONE. Where a syllable can be read two ways, spell it with a real
  /// English word rather than inventing a spelling. "paratope" shipped as
  /// "parra-tope" and was heard as PAR-uh-*top*; "parra-taupe" fixed it,
  /// because *taupe* has exactly one reading and *tope* does not. An invented
  /// spelling is a guess about a model's grapheme rules; a real word is a fact
  /// about English.
  ///
  /// That is a rule for ambiguous syllables, not a rule for rewriting. Tested
  /// against a listener the same day, "sarcomeer" beat both "sar-kuh-meer" and
  /// the real-word "sar-kuh-mere". An invented spelling that already sounds
  /// right is not improved by making it more principled.
  ///
  /// Hyphens are not the variable. "parra-taupe" beat "parratope" while
  /// "mullight" beat "mull-ight" — what decides it is whether each piece has
  /// one reading, not how the pieces are joined.
  ///
  /// Never ship one unheard. Every override in this catalogue that needed a
  /// second pass was one nobody had listened to:
  ///   tools/pronunciation_survey.py build --say word=respelling
  final String? say;

  final int freqRank;
  final String difficulty; // easy | medium | hard
  final List<String> tags;
  final Map<String, Gloss> gloss;

  const Word({
    required this.id,
    required this.lang,
    required this.word,
    required this.pos,
    this.say,
    required this.freqRank,
    required this.difficulty,
    required this.tags,
    required this.gloss,
  });

  factory Word.fromJson(Map<String, dynamic> j) {
    final glossJson = (j['gloss'] as Map<String, dynamic>);
    final gloss = <String, Gloss>{};
    glossJson.forEach((k, v) => gloss[k] = Gloss.fromJson(v as Map<String, dynamic>));
    return Word(
      id: j['id'] as String,
      lang: (j['lang'] as String?) ?? 'en',
      word: j['word'] as String,
      pos: j['pos'] as String,
      say: j['say'] as String?,
      freqRank: (j['freqRank'] as num).toInt(),
      difficulty: j['difficulty'] as String,
      tags: (j['tags'] as List).map((e) => e as String).toList(),
      gloss: gloss,
    );
  }

  /// The gloss for a locale, falling back to English.
  Gloss glossFor(String locale) => gloss[locale] ?? gloss['en'] ?? gloss.values.first;

  /// True if this word has a gloss in [locale].
  bool hasGloss(String locale) => gloss.containsKey(locale);
}
