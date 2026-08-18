import 'package:flutter_test/flutter_test.dart';
import 'package:qulex/game/track.dart';
import 'package:qulex/models/word.dart';

Word _w(String id, String difficulty, int rank, List<String> tags) => Word(
      id: id,
      lang: 'en',
      word: id,
      pos: 'noun',
      freqRank: rank,
      difficulty: difficulty,
      tags: tags,
      gloss: const {},
    );

void main() {
  test('the exam tracks are split per exam', () {
    final ids = kTracks.map((t) => t.id).toList();
    expect(ids, containsAll(<String>['sat', 'gre', 'ielts']));
    expect(ids.contains('test'), isFalse,
        reason: 'the pooled SAT/GRE/IELTS track is gone');
  });

  test('a track filter only matches its own exam', () {
    final ielts = kTracks.firstWhere((t) => t.id == 'ielts');
    expect(ielts.filter(_w('a', 'hard', 9000, ['IELTS'])), isTrue);
    expect(ielts.filter(_w('b', 'hard', 9000, ['GRE'])), isFalse);
  });

  group('poolForTrack', () {
    final ielts = kTracks.firstWhere((t) => t.id == 'ielts');

    test('tops a thin pool up to the target', () {
      final all = [
        for (var i = 0; i < 10; i++) _w('t$i', 'hard', 9000 + i, ['IELTS']),
        for (var i = 0; i < 500; i++) _w('o$i', 'hard', 5000 + i * 20, const []),
      ];
      final pool = poolForTrack(ielts, all, target: 200);
      expect(pool.length, 200);
      // The track's own words come first.
      expect(pool.take(10).every((w) => w.tags.contains('IELTS')), isTrue);
    });

    test('top-ups match the difficulty of what the track did find', () {
      final all = [
        for (var i = 0; i < 5; i++) _w('t$i', 'hard', 9000, ['IELTS']),
        for (var i = 0; i < 300; i++) _w('e$i', 'easy', 9000, const []),
      ];
      final pool = poolForTrack(ielts, all, target: 100);
      expect(pool.length, 5,
          reason: 'no hard words to top up with, so no easy ones are smuggled in');
    });

    test('a track that is already big enough is untouched', () {
      final fun = kTracks.firstWhere((t) => t.id == 'fun');
      final all = [for (var i = 0; i < 500; i++) _w('w$i', 'medium', 5000, const [])];
      expect(poolForTrack(fun, all, target: 200).length, 500);
    });

    test('a track matching nothing stays empty rather than inventing a pool', () {
      final all = [for (var i = 0; i < 300; i++) _w('w$i', 'easy', 3000, const [])];
      expect(poolForTrack(ielts, all, target: 200), isEmpty);
    });
  });
}
