import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qulex/models/word.dart';

/// Integrity checks on the shipped word catalogue.
///
/// This replaces the stock `widget_test.dart`, which still referenced the
/// Flutter counter template (`MyApp`) and had not compiled since the project
/// was created. It was never caught because CI ran `flutter analyze || true`
/// and no test step at all.
///
/// Reading the asset straight off disk rather than through rootBundle keeps
/// this a plain unit test — no binding, no async asset plumbing — while still
/// exercising the real Word.fromJson parser against the real 16k-entry file.
List<Word>? _cache;

List<Word> loadCatalogue() {
  if (_cache != null) return _cache!;
  final file = File('assets/words.json');
  expect(file.existsSync(), isTrue,
      reason: 'assets/words.json missing — run tests from the package root');
  final list = json.decode(file.readAsStringSync()) as List<dynamic>;
  return _cache = list
      .map((e) => Word.fromJson(e as Map<String, dynamic>))
      .toList(growable: false);
}

void main() {
  test('every entry parses and the catalogue is non-trivial', () {
    final words = loadCatalogue();
    // The exact figure is asserted in bundled_catalogue_test.dart, which owns
    // the identity of the shipped file. This one only cares that there is a
    // real catalogue here to run the rest of the checks against.
    expect(words.length, greaterThan(1000));
  });

  test('ids are unique', () {
    final words = loadCatalogue();
    final ids = words.map((w) => w.id).toSet();
    expect(ids.length, words.length, reason: 'duplicate word ids in catalogue');
  });

  test('every entry has a usable gloss', () {
    final words = loadCatalogue();
    for (final w in words.take(2000)) {
      expect(w.glossFor('en').correct, isNotEmpty, reason: 'empty gloss for ${w.id}');
    }
  });

  // Guards the mistake that shipped: heteronyms.dart carried a byPos rule
  // keyed on 'past', which was never a value here, so it could never fire.
  // If a new part of speech is introduced, this test fails and whoever adds
  // it should check the byPos keys in lib/services/heteronyms.dart.
  test('pos values stay within the known vocabulary', () {
    final words = loadCatalogue();
    const known = {'noun', 'verb', 'adjective', 'adverb', 'custom'};
    final seen = words.map((w) => w.pos).toSet();
    expect(seen.difference(known), isEmpty,
        reason: 'new POS value(s) — re-check byPos keys in heteronyms.dart');
  });

  // The four heteronym headwords in the catalogue are pinned to their own
  // reading so they no longer depend on the spelling-keyed table being right.
  // w_lead is the regression that shipped: a sales lead spoken as the metal.
  test('live heteronym entries are pinned to their sense', () {
    final words = loadCatalogue();
    const expected = {
      'w_lead': 'leed',
      'w_wound': 'woond',
      'w_wind': 'wined',
      'w_tear': 'tare',
    };
    for (final entry in expected.entries) {
      final w = words.firstWhere((w) => w.id == entry.key,
          orElse: () => throw StateError('${entry.key} missing from catalogue'));
      expect(w.say, entry.value, reason: '${entry.key} lost its pronunciation pin');
    }
  });

  test('say is null for ordinary words', () {
    final words = loadCatalogue();
    final pinned = words.where((w) => w.say != null).length;
    expect(pinned, lessThan(50),
        reason: 'pins should stay rare; a broad default suggests a parsing bug');
  });
}
