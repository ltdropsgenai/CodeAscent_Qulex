import 'word.dart';

/// One term→meaning pair in a user-created set.
class CustomEntry {
  final String term;
  final String meaning;
  const CustomEntry(this.term, this.meaning);

  Map<String, dynamic> toJson() => {'t': term, 'm': meaning};
  factory CustomEntry.fromJson(Map<String, dynamic> j) =>
      CustomEntry((j['t'] ?? '') as String, (j['m'] ?? '') as String);
}

/// A user-created / imported study set.
class CustomSet {
  final String id;
  String name;
  List<CustomEntry> entries;
  CustomSet({required this.id, required this.name, required this.entries});

  int get count => entries.length;

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'e': entries.map((e) => e.toJson()).toList()};
  factory CustomSet.fromJson(Map<String, dynamic> j) => CustomSet(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        entries: ((j['e'] as List?) ?? const [])
            .map((e) => CustomEntry.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}

/// Parse pasted text (Quizlet/Anki style) into entries. Each line becomes a
/// term/meaning pair split on the first tab, then " - ", then the first comma.
List<CustomEntry> parseImport(String text) {
  final out = <CustomEntry>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    String? t, m;
    if (line.contains('\t')) {
      final i = line.indexOf('\t');
      t = line.substring(0, i);
      m = line.substring(i + 1);
    } else if (line.contains(' - ')) {
      final i = line.indexOf(' - ');
      t = line.substring(0, i);
      m = line.substring(i + 3);
    } else if (line.contains(',')) {
      final i = line.indexOf(',');
      t = line.substring(0, i);
      m = line.substring(i + 1);
    }
    if (t != null && m != null && t.trim().isNotEmpty && m.trim().isNotEmpty) {
      out.add(CustomEntry(t.trim(), m.trim()));
    }
  }
  return out;
}

/// Turn a set into playable synthetic [Word]s. Distractors come from the other
/// meanings in the set, topped up from the main [library] when the set is small.
List<Word> wordsFromSet(CustomSet set,
    {required List<Word> library, required String locale}) {
  final meanings = set.entries.map((e) => e.meaning).toList();
  final words = <Word>[];
  for (var i = 0; i < set.entries.length; i++) {
    final e = set.entries[i];
    final others = <String>[];
    final pool = [
      for (var j = 0; j < meanings.length; j++)
        if (j != i && meanings[j] != e.meaning) meanings[j]
    ]..shuffle();
    others.addAll(pool.take(2));
    var k = 0;
    while (others.length < 2 && library.isNotEmpty) {
      final w = library[(i * 7 + k) % library.length];
      final m = w.glossFor(locale).correct;
      if (m != e.meaning && !others.contains(m)) others.add(m);
      k++;
      if (k > library.length) break;
    }
    // Pad with distinct placeholders so options never duplicate.
    if (others.length < 2 && !others.contains('—')) others.add('—');
    if (others.length < 2) others.add('···');
    final g = Gloss(
        correct: e.meaning, distractors: others.take(2).toList(), example: '');
    words.add(Word(
      id: 'set:${set.id}:$i',
      lang: 'en',
      word: e.term,
      pos: 'custom',
      freqRank: 5000,
      difficulty: 'medium',
      tags: const ['custom'],
      gloss: {locale: g, 'en': g},
    ));
  }
  words.shuffle();
  return words;
}
