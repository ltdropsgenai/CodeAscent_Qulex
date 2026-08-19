import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qulex/data/progress_store.dart';
import 'package:qulex/game/game_controller.dart';
import 'package:qulex/game/level.dart';
import 'package:qulex/game/track.dart';
import 'package:qulex/models/word.dart';

Word w(String id, String difficulty, int rank, List<String> tags) => Word(
      id: id,
      lang: 'en',
      word: id,
      pos: 'noun',
      freqRank: rank,
      difficulty: difficulty,
      tags: tags,
      gloss: {
        'en': Gloss(
            correct: 'meaning of $id',
            distractors: const ['wrong a', 'wrong b'],
            example: 'an example')
      },
    );

/// Mirrors the shipped catalogue where it matters: GRE is tagged on hard and
/// medium words only — there is not one easy GRE word in the 16,808.
List<Word> catalogue() => [
      for (var i = 0; i < 400; i++) w('easy$i', 'easy', i, const ['everyday']),
      for (var i = 0; i < 400; i++) w('hard$i', 'hard', 9000 + i, const ['GRE']),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('difficulty=easy + GRE track widens instead of throwing', () async {
    final store = ProgressStore();
    await store.load();
    final all = catalogue();
    final gre = kTracks.firstWhere((t) => t.id == 'gre');

    // The condition that used to be fatal is still exactly true...
    final pool = matchLevel(all, pref: DifficultyPref.easy, placementRank: 0);
    expect(pool.length, 400);
    expect(poolForTrack(gre, pool), isEmpty,
        reason: 'no easy word carries the GRE tag');

    // ...but the controller now steps outwards rather than dealing nothing.
    final c = GameController(all,
        store: store,
        locale: 'en',
        difficultyPref: DifficultyPref.easy,
        mode: GameMode.quickPlay);
    c.start(gre); // used to throw RangeError
    expect(c.dealtEmpty, isFalse);
    expect(c.total, GameController.roundsPerMatch);
    expect(c.current.word, isNotEmpty);
    expect(c.phase, Phase.question);
    c.dispose();
  });

  test('review mode with every word suspended still deals a round', () async {
    final store = ProgressStore();
    await store.load();
    final all = catalogue().take(60).toList();
    for (final x in all) {
      await store.markKnown(x.id);
    }
    expect(store.allSuspended, isTrue);

    final c =
        GameController(all, store: store, locale: 'en', mode: GameMode.review);
    c.start(kTracks.first); // used to throw RangeError
    expect(c.dealtEmpty, isFalse);
    expect(c.current.word, isNotEmpty);
    c.dispose();
  });

  test('an empty catalogue reports dealtEmpty rather than crashing', () {
    final store = ProgressStore();
    final c = GameController(const <Word>[], store: store, locale: 'en');
    c.start(kTracks.first);
    expect(c.dealtEmpty, isTrue);
    expect(c.phase, Phase.finished,
        reason: 'the screen shows an explanation, not a question');
    c.dispose();
  });

  test('the Daily Challenge is the same deck for every learner', () {
    final all = catalogue();
    final store = ProgressStore();

    // A beginner and an advanced learner, on the same day.
    final beginner = GameController(all,
        store: store,
        locale: 'en',
        mode: GameMode.daily,
        difficultyPref: DifficultyPref.easy);
    final advanced = GameController(all,
        store: store,
        locale: 'en',
        mode: GameMode.daily,
        difficultyPref: DifficultyPref.hard);
    beginner.start(kTracks.first);
    advanced.start(kTracks.first);

    List<String> ids(GameController c) =>
        [for (var i = 0; i < c.total; i++) c.deckIdAt(i)];
    expect(ids(beginner), equals(ids(advanced)),
        reason: 'Daily is drawn from the whole catalogue, not a level pool');
    beginner.dispose();
    advanced.dispose();
  });

  test('control: a normal deck still starts fine', () async {
    final store = ProgressStore();
    await store.load();
    final c = GameController(catalogue(), store: store, locale: 'en');
    c.start(kTracks.first);
    expect(c.total, 10);
    expect(c.current.word, isNotEmpty);
    c.dispose();
  });
}
