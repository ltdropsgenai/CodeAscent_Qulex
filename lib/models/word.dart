/// A per-language meaning of a word: the correct definition, two distractors,
/// and an example sentence — all in one language.
class Gloss {
  final String correct;
  final List<String> distractors;
  final String example;

  const Gloss({
    required this.correct,
    required this.distractors,
    required this.example,
  });

  factory Gloss.fromJson(Map<String, dynamic> j) => Gloss(
        correct: j['correct'] as String,
        distractors:
            (j['distractors'] as List).map((e) => e as String).toList(),
        example: ((j['example'] as Map<String, dynamic>)['text']) as String,
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
  final int freqRank;
  final String difficulty; // easy | medium | hard
  final List<String> tags;
  final Map<String, Gloss> gloss;

  const Word({
    required this.id,
    required this.lang,
    required this.word,
    required this.pos,
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
