import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The attested-usage citations, and the two ways they can silently rot.
///
/// `gloss.en.attested` holds a sentence somebody actually wrote, mined from
/// Tatoeba by tools/mine_attested_examples.py. Two things about it are load
/// bearing and neither is self-evident from reading the JSON.
///
/// FIRST: the sentence has to contain the word. A citation that does not
/// show the headword in use is not a citation, it is a random sentence, and
/// a regeneration with a broken inflection rule would produce thousands of
/// them while looking completely normal in a spot check.
///
/// SECOND: the corpus is CC-BY. Attribution is a condition of use, not a
/// nicety. An entry carrying the text without the credit is a licence
/// breach shipped in a binary, which is not something to discover from a
/// complaint.
///
/// The count is pinned for the same reason kBundledCatalogueEntries is: a
/// regeneration that quietly halves coverage otherwise passes everything.
void main() {
  // 9,502 of 16,808 headwords. The rest are the hard technical tail that a
  // conversational corpus does not reach — 96% of easy words are covered,
  // 31% of hard ones. Update deliberately, never to make a red test green.
  const expectedAttested = 9501;

  late List<dynamic> words;

  setUpAll(() {
    words = jsonDecode(File('assets/words.json').readAsStringSync()) as List;
  });

  test('coverage has not silently changed', () {
    final n = words
        .where((w) => (w['gloss']?['en']?['attested']) != null)
        .length;
    expect(n, expectedAttested,
        reason: 'attested-example coverage moved from $expectedAttested to $n. '
            'If you re-ran the miner on purpose, update expectedAttested in '
            'this file in the same commit as the catalogue.');
  });

  test('every citation actually contains the word it cites', () {
    final misses = <String>[];
    for (final w in words) {
      final att = w['gloss']?['en']?['attested'];
      if (att == null) continue;
      final head = (w['word'] as String).toLowerCase();
      final text = (att['text'] as String).toLowerCase();
      // The miner matches inflections, so the stem is what must survive:
      // "buries" attests "bury", "clipping" attests "clip".
      final stem = head.length > 4 ? head.substring(0, head.length - 1) : head;
      if (!text.contains(stem)) misses.add('${w['word']}: ${att['text']}');
    }
    expect(misses, isEmpty,
        reason: 'citations that do not contain their headword '
            '(showing first 5): ${misses.take(5).join(" | ")}');
  });

  test('every citation carries its licence', () {
    final unattributed = <String>[];
    for (final w in words) {
      final att = w['gloss']?['en']?['attested'];
      if (att == null) continue;
      final credit = att['attribution'] as String?;
      if (credit == null ||
          !credit.contains('CC BY') ||
          !credit.contains('tatoeba.org/sentences/')) {
        unattributed.add(w['word'] as String);
      }
      expect(att['source'], 'tatoeba');
    }
    expect(unattributed, isEmpty,
        reason: 'CC-BY text shipped without attribution: '
            '${unattributed.take(5).join(", ")}');
  });

  test('citations are English only, so no learner sees a mismatched pair', () {
    // example/example2 are a parallel translation set. An attested sentence in
    // a non-English gloss would sit under an English line it does not
    // translate, which is the fault this app shipped in August.
    final leaked = <String>[];
    for (final w in words) {
      for (final lg in const ['es', 'pt', 'it', 'fr']) {
        if (w['gloss']?[lg]?['attested'] != null) {
          leaked.add('${w['word']}/$lg');
        }
      }
    }
    expect(leaked, isEmpty,
        reason: 'attested citations must not be translated: '
            '${leaked.take(5).join(", ")}');
  });
}
