import 'package:flutter_test/flutter_test.dart';
import 'package:qulex/game/level.dart';
import 'package:qulex/models/word.dart';

Word _w(String id, String difficulty) => Word(
      id: id,
      lang: 'en',
      word: id,
      pos: 'noun',
      freqRank: 5000,
      difficulty: difficulty,
      tags: const [],
      gloss: const {},
    );

List<Word> _pool({int easy = 0, int medium = 0, int hard = 0}) => [
      for (var i = 0; i < easy; i++) _w('e$i', 'easy'),
      for (var i = 0; i < medium; i++) _w('m$i', 'medium'),
      for (var i = 0; i < hard; i++) _w('h$i', 'hard'),
    ];

void main() {
  group('auto band from placement rank', () {
    test('an unplaced learner is protected from hard words', () {
      expect(
        allowedDifficulties(pref: DifficultyPref.auto, placementRank: 0),
        {'easy', 'medium'},
      );
    });

    test('a low rank stays on easy/medium', () {
      expect(
        allowedDifficulties(pref: DifficultyPref.auto, placementRank: 3500),
        {'easy', 'medium'},
      );
    });

    test('a mid rank opens up the whole range', () {
      expect(
        allowedDifficulties(pref: DifficultyPref.auto, placementRank: 6000),
        {'easy', 'medium', 'hard'},
      );
    });

    test('a high rank drops easy words', () {
      expect(
        allowedDifficulties(pref: DifficultyPref.auto, placementRank: 20000),
        {'medium', 'hard'},
      );
    });
  });

  group('explicit preference overrides placement', () {
    test('easy wins even at a high rank', () {
      expect(
        allowedDifficulties(pref: DifficultyPref.easy, placementRank: 30000),
        {'easy'},
      );
    });

    test('hard wins even unplaced', () {
      expect(
        allowedDifficulties(pref: DifficultyPref.hard, placementRank: 0),
        {'hard'},
      );
    });
  });

  group('matchLevel', () {
    test('filters the pool to the allowed bands', () {
      final out = matchLevel(_pool(easy: 50, medium: 50, hard: 50),
          pref: DifficultyPref.auto, placementRank: 0);
      expect(out.length, 100);
      expect(out.any((w) => w.difficulty == 'hard'), isFalse);
    });

    test('falls back to the full pool rather than deal a starved round', () {
      // Only 5 easy words available, well under minPool.
      final pool = _pool(easy: 5, hard: 200);
      final out = matchLevel(pool, pref: DifficultyPref.easy, placementRank: 0);
      expect(out.length, pool.length,
          reason: 'should return everything rather than a 5-word deck');
    });

    test('an all-bands result is passed through untouched', () {
      final pool = _pool(easy: 50, medium: 50, hard: 50);
      final out = matchLevel(pool,
          pref: DifficultyPref.auto, placementRank: 6000);
      expect(identical(out, pool), isTrue);
    });
  });

  group('producing modes', () {
    test('locked until placed', () {
      expect(producingModesUnlocked(0), isFalse);
      expect(producingModesUnlocked(1), isTrue);
      expect(producingModesUnlocked(9000), isTrue);
    });
  });
}
