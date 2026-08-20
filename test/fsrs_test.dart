import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qulex/data/progress_store.dart';

import 'package:qulex/game/srs.dart';
import 'package:qulex/models/progress.dart';

/// Checks the FSRS-5 port against the reference implementation.
///
/// Every EXPECTED number below was produced by running py-fsrs 4.1.1 — the
/// upstream Python package, same default parameter vector — and printing the
/// result with full double precision. They are not values I computed by hand
/// and they are not this implementation's own output snapshotted back as a
/// golden, which would only prove the code equals itself. A tolerance of 1e-9
/// is tight enough that a transposed weight index or a sign error cannot slip
/// through, and loose enough to absorb the last bit of double arithmetic
/// ordering between Dart and Python.
void main() {
  const eps = 1e-9;

  group('forgetting curve', () {
    test('matches the reference', () {
      expect(Fsrs.factor, closeTo(0.23456790123456783, eps));
      expect(Fsrs.retrievability(0, 1.0), closeTo(1.0, eps));
      expect(Fsrs.retrievability(5, 10.0), closeTo(0.946058996209746, eps));
      expect(Fsrs.retrievability(30, 7.5), closeTo(0.71827819602086, eps));
      expect(Fsrs.retrievability(0.5, 0.4), closeTo(0.8793575437428567, eps));
    });

    test('R is exactly 0.9 when elapsed equals stability', () {
      // This is the identity that gives stability its units. If it ever stops
      // holding, DECAY and FACTOR have drifted apart and every interval in the
      // app is silently wrong.
      for (final s in [0.1, 1.0, 7.0, 365.0]) {
        expect(Fsrs.retrievability(s, s), closeTo(0.9, 1e-12));
      }
    });

    test('R decays monotonically and stays in (0,1]', () {
      var prev = 1.0;
      for (var t = 0.0; t < 400; t += 3.7) {
        final r = Fsrs.retrievability(t, 12.0);
        expect(r, lessThanOrEqualTo(prev + eps));
        expect(r, greaterThan(0));
        expect(r, lessThanOrEqualTo(1.0));
        prev = r;
      }
    });
  });

  group('interval', () {
    test('matches the reference', () {
      expect(Fsrs.intervalDays(1.0, 0.9), closeTo(1.0, eps));
      expect(Fsrs.intervalDays(10.0, 0.9), closeTo(10.0, eps));
      expect(Fsrs.intervalDays(10.0, 0.95), closeTo(4.6056276425134905, eps));
      expect(Fsrs.intervalDays(10.0, 0.85), closeTo(16.374066654525596, eps));
      expect(Fsrs.intervalDays(3.0, 0.8), closeTo(7.1940789473684195, eps));
    });

    test('higher retention always means a shorter interval', () {
      // The Settings dial promises exactly this and nothing else. Relaxed must
      // never review more often than Intense, at any stability.
      for (final s in [0.5, 3.0, 40.0, 900.0]) {
        expect(
            Fsrs.intervalDays(s, 0.95), lessThan(Fsrs.intervalDays(s, 0.90)));
        expect(
            Fsrs.intervalDays(s, 0.90), lessThan(Fsrs.intervalDays(s, 0.85)));
      }
    });
  });

  group('initial state', () {
    test('S0 and D0 match the reference', () {
      expect(Fsrs.initialStability(Grade.again), closeTo(0.40255, eps));
      expect(Fsrs.initialStability(Grade.hard), closeTo(1.18385, eps));
      expect(Fsrs.initialStability(Grade.good), closeTo(3.173, eps));
      expect(Fsrs.initialStability(Grade.easy), closeTo(15.69105, eps));

      expect(Fsrs.initialDifficulty(Grade.again), closeTo(7.1949, eps));
      expect(
          Fsrs.initialDifficulty(Grade.hard), closeTo(6.488305268471453, eps));
      expect(
          Fsrs.initialDifficulty(Grade.good), closeTo(5.282434422319005, eps));
      expect(
          Fsrs.initialDifficulty(Grade.easy), closeTo(3.2245015893713678, eps));
    });
  });

  group('difficulty update', () {
    test('matches the reference', () {
      expect(Fsrs.nextDifficulty(5.0, Grade.again),
          closeTo(6.607035107311108, eps));
      expect(Fsrs.nextDifficulty(5.0, Grade.hard),
          closeTo(5.7994339073111085, eps));
      expect(Fsrs.nextDifficulty(5.0, Grade.good),
          closeTo(4.991832707311108, eps));
      expect(Fsrs.nextDifficulty(5.0, Grade.easy),
          closeTo(4.184231507311108, eps));
      expect(Fsrs.nextDifficulty(7.3, Grade.again),
          closeTo(8.153462003311107, eps));
      expect(Fsrs.nextDifficulty(1.0, Grade.easy), closeTo(1.0, eps));
    });

    test('stays inside 1..10 under any run of answers', () {
      for (final g in Grade.values) {
        var d = 5.0;
        for (var i = 0; i < 200; i++) {
          d = Fsrs.nextDifficulty(d, g);
          expect(d, inInclusiveRange(1.0, 10.0));
        }
      }
    });
  });

  group('stability update', () {
    test('short-term matches the reference', () {
      expect(Fsrs.shortTermStability(1.0, Grade.again),
          closeTo(0.5010285241935083, eps));
      expect(Fsrs.shortTermStability(1.0, Grade.good),
          closeTo(1.4077712147375412, eps));
      expect(Fsrs.shortTermStability(5.0, Grade.easy),
          closeTo(11.79877446800273, eps));
    });

    test('after recall matches the reference', () {
      expect(Fsrs.recallStability(5.0, 10.0, 0.9, Grade.hard),
          closeTo(15.31391211425268, eps));
      expect(Fsrs.recallStability(5.0, 10.0, 0.9, Grade.good),
          closeTo(32.954263992452184, eps));
      expect(Fsrs.recallStability(5.0, 10.0, 0.9, Grade.easy),
          closeTo(78.62865848463353, eps));
      expect(Fsrs.recallStability(2.0, 1.0, 0.7, Grade.good),
          closeTo(16.102330496633375, eps));
      expect(Fsrs.recallStability(9.0, 50.0, 0.95, Grade.good),
          closeTo(65.38712769986812, eps));
    });

    test('after a lapse matches the reference', () {
      expect(Fsrs.forgetStability(5.0, 10.0, 0.9),
          closeTo(2.107696257677866, eps));
      expect(Fsrs.forgetStability(2.0, 1.0, 0.7),
          closeTo(0.7103426959802099, eps));
      expect(Fsrs.forgetStability(9.0, 50.0, 0.95),
          closeTo(3.758208942042706, eps));
      expect(Fsrs.forgetStability(5.0, 0.4, 0.99),
          closeTo(0.17409453741681874, eps));
    });

    test('a lapse never increases stability', () {
      for (final s in [0.1, 1.0, 10.0, 400.0]) {
        for (final d in [1.0, 5.0, 10.0]) {
          for (final r in [0.3, 0.7, 0.99]) {
            expect(Fsrs.forgetStability(d, s, r), lessThan(s));
          }
        }
      }
    });

    test('reviewing later is worth more than reviewing sooner', () {
      // The headline claim of the whole model: leaving it until you have
      // nearly forgotten buys more stability than drilling it while it is
      // fresh. If this inverts, FSRS is doing nothing a box ladder could not.
      final fresh = Fsrs.recallStability(5.0, 10.0, 0.99, Grade.good);
      final due = Fsrs.recallStability(5.0, 10.0, 0.90, Grade.good);
      final overdue = Fsrs.recallStability(5.0, 10.0, 0.70, Grade.good);
      expect(due, greaterThan(fresh));
      expect(overdue, greaterThan(due));
    });

    test('an easy word gains more than a hard one', () {
      final hard = Fsrs.recallStability(5.0, 10.0, 0.9, Grade.hard);
      final good = Fsrs.recallStability(5.0, 10.0, 0.9, Grade.good);
      final easy = Fsrs.recallStability(5.0, 10.0, 0.9, Grade.easy);
      expect(good, greaterThan(hard));
      expect(easy, greaterThan(good));
    });

    test('a difficult word gains less than an easy one, forever', () {
      for (final s in [1.0, 10.0, 100.0]) {
        expect(Fsrs.recallStability(9.5, s, 0.9, Grade.good),
            lessThan(Fsrs.recallStability(2.0, s, 0.9, Grade.good)));
      }
    });
  });

  group('grade mapping', () {
    test('a miss is always Again, however fast', () {
      expect(Fsrs.gradeFor(correct: false, clockLeft: 0.99), Grade.again);
      expect(Fsrs.gradeFor(correct: false, clockLeft: 0.0), Grade.again);
      expect(Fsrs.gradeFor(correct: false, clockLeft: null), Grade.again);
    });

    test('the clock separates Hard / Good / Easy', () {
      expect(Fsrs.gradeFor(correct: true, clockLeft: 0.95), Grade.easy);
      expect(Fsrs.gradeFor(correct: true, clockLeft: 0.75), Grade.easy);
      expect(Fsrs.gradeFor(correct: true, clockLeft: 0.74), Grade.good);
      expect(Fsrs.gradeFor(correct: true, clockLeft: 0.25), Grade.good);
      expect(Fsrs.gradeFor(correct: true, clockLeft: 0.24), Grade.hard);
      expect(Fsrs.gradeFor(correct: true, clockLeft: 0.0), Grade.hard);
    });

    test('untimed modes have no signal, so everything correct is Good', () {
      expect(Fsrs.gradeFor(correct: true, clockLeft: null), Grade.good);
    });
  });

  group('the scheduler', () {
    SrsOutcome run({
      SrsState state = SrsState.fresh,
      int step = 0,
      double stability = 0,
      double difficulty = 0,
      double? elapsedDays,
      required Grade grade,
      double retention = 0.9,
    }) =>
        Fsrs.review(
          state: state,
          step: step,
          stability: stability,
          difficulty: difficulty,
          elapsedDays: elapsedDays,
          grade: grade,
          desiredRetention: retention,
          fuzzSeed: 'seed',
        );

    test('a new word walks the learning steps', () {
      final first = run(grade: Grade.good);
      expect(first.state, SrsState.learning);
      expect(first.step, 1);
      expect(first.wait, Fsrs.learningSteps[1]); // 10 minutes

      final second = run(
          state: SrsState.learning,
          step: 1,
          stability: first.stability,
          difficulty: first.difficulty,
          elapsedDays: 10 / 1440,
          grade: Grade.good);
      expect(second.state, SrsState.review);
      expect(second.step, -1);
      expect(second.wait.inMinutes, greaterThan(60));
    });

    test('Easy skips the ladder entirely', () {
      final o = run(grade: Grade.easy);
      expect(o.state, SrsState.review);
      expect(o.wait.inDays, greaterThan(7));
    });

    test('a miss inside learning goes back to the first step', () {
      final o = run(state: SrsState.learning, step: 1, grade: Grade.again);
      expect(o.state, SrsState.learning);
      expect(o.step, 0);
      expect(o.wait, Fsrs.learningSteps[0]); // back inside the round
    });

    test('missing a graduated word drops it into relearning, not to zero', () {
      final o = run(
          state: SrsState.review,
          step: -1,
          stability: 60.0,
          difficulty: 5.0,
          elapsedDays: 60,
          grade: Grade.again);
      expect(o.state, SrsState.relearning);
      expect(o.wait, Fsrs.relearningSteps[0]);
      // The whole point: sixty days of stability becomes a few days, not one
      // minute. The old box ladder sent it to box 0 and threw all of it away.
      expect(o.stability, greaterThan(1.0));
      expect(o.stability, lessThan(60.0));
    });

    test('a same-day repeat is worth much less than a spaced one', () {
      final sameDay = run(
          state: SrsState.review,
          step: -1,
          stability: 10.0,
          difficulty: 5.0,
          elapsedDays: 0.2,
          grade: Grade.good);
      final spaced = run(
          state: SrsState.review,
          step: -1,
          stability: 10.0,
          difficulty: 5.0,
          elapsedDays: 10,
          grade: Grade.good);
      expect(sameDay.stability, lessThan(spaced.stability));
    });

    test('intervals never exceed the one-year ceiling', () {
      final o = run(
          state: SrsState.review,
          step: -1,
          stability: 1e9,
          difficulty: 1.0,
          elapsedDays: 1e6,
          grade: Grade.easy);
      expect(o.wait.inDays, lessThanOrEqualTo(Fsrs.maximumIntervalDays));
    });

    test('fuzz is deterministic and stays within its band', () {
      final a = run(
          state: SrsState.review,
          step: -1,
          stability: 30.0,
          difficulty: 5.0,
          elapsedDays: 30,
          grade: Grade.good);
      final b = run(
          state: SrsState.review,
          step: -1,
          stability: 30.0,
          difficulty: 5.0,
          elapsedDays: 30,
          grade: Grade.good);
      expect(a.wait, b.wait, reason: 'same state must schedule the same day');

      // Different seeds must land within +/-5% of the unfuzzed interval.
      final base = Fsrs.intervalDays(a.stability, 0.9);
      for (final seed in ['w_alpha:3', 'w_beta:7', 'w_gamma:11']) {
        final o = Fsrs.review(
            state: SrsState.review,
            step: -1,
            stability: 30.0,
            difficulty: 5.0,
            elapsedDays: 30,
            grade: Grade.good,
            desiredRetention: 0.9,
            fuzzSeed: seed);
        final days = o.wait.inMinutes / 1440.0;
        expect(days, greaterThan(base * 0.94));
        expect(days, lessThan(base * 1.06));
      }
    });

    test('a stronger word is always scheduled further out', () {
      Duration waitFor(double s) => run(
            state: SrsState.review,
            step: -1,
            stability: s,
            difficulty: 5.0,
            elapsedDays: s,
            grade: Grade.good,
          ).wait;
      expect(waitFor(1.0), lessThan(waitFor(10.0)));
      expect(waitFor(10.0), lessThan(waitFor(100.0)));
    });
  });

  group('migration off the Leitner boxes', () {
    test('every old box lands somewhere sane', () {
      // Boxes 0 and 1 were the sub-hour steps and stay as learning steps;
      // 2..5 were real intervals and convert straight to stability in days.
      final expected = <int, double>{
        2: 0.1, // 60 min, floored at 0.1 days
        3: 1.0, // 1 day
        4: 3.0, // 3 days
        5: 7.0, // 7 days
      };
      expected.forEach((box, days) {
        final m = Fsrs.fromLegacyBox(box: box, seen: 6, correct: 5);
        expect(m.state, SrsState.review, reason: 'box $box');
        expect(m.stability, closeTo(days, 1e-9), reason: 'box $box');
        expect(m.difficulty, inInclusiveRange(1.0, 10.0));
      });

      for (final box in [0, 1]) {
        final m = Fsrs.fromLegacyBox(box: box, seen: 2, correct: 1);
        expect(m.state, SrsState.learning);
        expect(m.step, box);
      }
    });

    test('an unseen word stays fresh rather than becoming learning', () {
      final m = Fsrs.fromLegacyBox(box: 0, seen: 0, correct: 0);
      expect(m.state, SrsState.fresh);
    });

    test('difficulty reflects the accuracy actually recorded', () {
      final good = Fsrs.fromLegacyBox(box: 3, seen: 20, correct: 20);
      final bad = Fsrs.fromLegacyBox(box: 3, seen: 20, correct: 4);
      expect(bad.difficulty, greaterThan(good.difficulty));
      expect(good.difficulty, inInclusiveRange(1.0, 10.0));
      expect(bad.difficulty, inInclusiveRange(1.0, 10.0));
    });

    test('too little history means no claim, just the default', () {
      // One unlucky miss must not brand a word as permanently hard.
      final base = Fsrs.initialDifficulty(Grade.good);
      expect(Fsrs.fromLegacyBox(box: 3, seen: 1, correct: 0).difficulty,
          closeTo(base, 1e-9));
      expect(Fsrs.fromLegacyBox(box: 3, seen: 3, correct: 3).difficulty,
          closeTo(base, 1e-9));
    });

    test('an out-of-range box does not throw', () {
      expect(() => Fsrs.fromLegacyBox(box: -3, seen: 1, correct: 1),
          returnsNormally);
      expect(() => Fsrs.fromLegacyBox(box: 99, seen: 1, correct: 1),
          returnsNormally);
    });
  });

  group('WordProgress serialisation', () {
    test('reads a record written by the old build', () {
      final wp = WordProgress.fromJson(
          {'box': 4, 'seen': 9, 'correct': 7, 'due': 123456789});
      expect(wp.stability, closeTo(3.0, 1e-9));
      expect(wp.state, SrsState.review);
      expect(wp.dueAtMillis, 123456789);
      expect(wp.seen, 9);
      // The old model never stored a review timestamp, and inventing one would
      // fake a same-day review on the learner's next answer.
      expect(wp.lastReviewMillis, 0);
    });

    test('round-trips the new shape exactly', () {
      final wp = WordProgress(
        stability: 12.5,
        difficulty: 6.25,
        state: SrsState.relearning,
        step: 0,
        seen: 11,
        correct: 8,
        lapses: 2,
        dueAtMillis: 999,
        lastReviewMillis: 888,
        suspended: true,
      );
      final back = WordProgress.fromJson(wp.toJson());
      expect(back.stability, wp.stability);
      expect(back.difficulty, wp.difficulty);
      expect(back.state, wp.state);
      expect(back.step, wp.step);
      expect(back.lapses, wp.lapses);
      expect(back.lastReviewMillis, wp.lastReviewMillis);
      expect(back.suspended, isTrue);
    });

    test('a corrupt state index does not throw', () {
      final wp = WordProgress.fromJson({'s': 1.0, 'st': 99, 'seen': 1});
      expect(wp.state, isNotNull);
    });

    test('"known" means three weeks, not one hour', () {
      expect(WordProgress(state: SrsState.review, stability: 20.9).isKnown,
          isFalse);
      expect(WordProgress(state: SrsState.review, stability: 21.0).isKnown,
          isTrue);
      // Still walking the learning steps is not knowing it, at any stability.
      expect(WordProgress(state: SrsState.learning, stability: 90).isKnown,
          isFalse);
    });
  });
  // ---------------------------------------------------------------------------
  // Wiring
  //
  // Everything above tests the model. None of it tests what actually ships,
  // which is ProgressStore.recordAnswer calling into it with real clocks and
  // real persistence. These drive the store the way GameController does.
  // ---------------------------------------------------------------------------
  group('through the store', () {
    const day = 86400000;

    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a word learned well is scheduled further out each time', () async {
      final s = ProgressStore();
      await s.load();
      var now = 1770000000000;
      final gaps = <int>[];

      for (var i = 0; i < 6; i++) {
        await s.recordAnswer('w', true, now, clockLeft: 0.9); // fast = Easy
        final wp = s.progressFor('w');
        gaps.add(wp.dueAtMillis - now);
        now = wp.dueAtMillis; // answer it exactly when it comes due
      }

      // Past the two learning steps, every interval must exceed the last —
      // until it reaches the one-year ceiling, at which point equal is the
      // correct answer rather than a regression.
      const cap = 365 * day;
      for (var i = 3; i < gaps.length; i++) {
        if (gaps[i - 1] >= cap) {
          expect(gaps[i], gaps[i - 1], reason: 'saturated, so it should hold');
        } else {
          expect(gaps[i], greaterThan(gaps[i - 1]),
              reason: 'interval $i (${gaps[i] / day}d) did not grow on '
                  '${gaps[i - 1] / day}d');
        }
      }
      expect(gaps.last, greaterThan(30 * day),
          reason: 'six clean answers should buy more than a month');
      expect(gaps.last, lessThanOrEqualTo(cap),
          reason: 'and never more than the ceiling');
    });

    test('a word answered slowly grows more slowly than one answered fast',
        () async {
      Future<int> runWith(double clockLeft) async {
        SharedPreferences.setMockInitialValues({});
        final s = ProgressStore();
        await s.load();
        var now = 1770000000000;
        for (var i = 0; i < 5; i++) {
          await s.recordAnswer('w', true, now, clockLeft: clockLeft);
          now = s.progressFor('w').dueAtMillis;
        }
        return s.progressFor('w').dueAtMillis - 1770000000000;
      }

      final fast = await runWith(0.90); // Easy
      final slow = await runWith(0.10); // Hard — nearly at the buzzer
      expect(fast, greaterThan(slow),
          reason: 'the clock is the only confidence signal the game has; if '
              'it does not change the schedule it is not being used');
    });

    test('a lapse costs a lot but not everything', () async {
      final s = ProgressStore();
      await s.load();
      var now = 1770000000000;
      for (var i = 0; i < 5; i++) {
        await s.recordAnswer('w', true, now, clockLeft: 0.9);
        now = s.progressFor('w').dueAtMillis;
      }
      final before = s.progressFor('w').stability;
      expect(before, greaterThan(30));

      await s.recordAnswer('w', false, now);
      final after = s.progressFor('w');
      expect(after.stability, lessThan(before));
      expect(after.lapses, 1);
      expect(after.state, SrsState.relearning);
      // The old Leitner ladder sent this straight back to box 0 — one minute,
      // all of it gone. FSRS keeps a meaningful fraction.
      expect(after.stability, greaterThan(1.0),
          reason: 'a single miss must not erase weeks of work');
    });

    test('a lapse on a brand-new word is not counted as a lapse', () async {
      // "Lapses" means words you had and lost. Getting a word wrong the first
      // time you ever see it is not that, and counting it would make the
      // number useless.
      final s = ProgressStore();
      await s.load();
      await s.recordAnswer('w', false, 1770000000000);
      expect(s.progressFor('w').lapses, 0);
    });

    test('review intensity actually changes the schedule', () async {
      Future<int> runAt(double retention) async {
        SharedPreferences.setMockInitialValues({});
        final s = ProgressStore();
        await s.load();
        s.desiredRetention = retention;
        var now = 1770000000000;
        for (var i = 0; i < 4; i++) {
          await s.recordAnswer('w', true, now, clockLeft: 0.7);
          now = s.progressFor('w').dueAtMillis;
        }
        return s.progressFor('w').dueAtMillis - 1770000000000;
      }

      final relaxed = await runAt(0.85);
      final normal = await runAt(0.90);
      final intense = await runAt(0.95);
      expect(relaxed, greaterThan(normal));
      expect(normal, greaterThan(intense));
    });

    test('two words do not land on the same day', () async {
      // What the fuzz is for. Without it, everything learned in one session
      // comes back as a single wall weeks later.
      final s = ProgressStore();
      await s.load();
      final due = <int>{};
      for (var i = 0; i < 30; i++) {
        var now = 1770000000000;
        for (var r = 0; r < 5; r++) {
          await s.recordAnswer('w\$i', true, now, clockLeft: 0.9);
          now = s.progressFor('w\$i').dueAtMillis;
        }
        due.add(s.progressFor('w\$i').dueAtMillis ~/ day);
      }
      expect(due.length, greaterThan(1),
          reason: '30 identically-answered words all came back the same day');
    });

    test('an unseen word is due immediately, not never', () async {
      final s = ProgressStore();
      await s.load();
      expect(s.progressFor('never-touched').dueAtMillis, 0);
      expect(s.dueCount(1770000000000), 0,
          reason: 'unseen is not the same as due for review');
    });

    test('marking a word known, then bringing it back, is coherent', () async {
      final s = ProgressStore();
      await s.load();
      await s.recordAnswer('w', true, 1770000000000, clockLeft: 0.9);
      await s.markKnown('w');
      expect(s.progressFor('w').suspended, isTrue);
      expect(s.progressFor('w').isKnown, isTrue);

      final n = await s.resurfaceMastered();
      expect(n, 1);
      final wp = s.progressFor('w');
      expect(wp.suspended, isFalse);
      expect(wp.stability, lessThanOrEqualTo(7.0),
          reason: 'asking to see it again means the claim was optimistic');
    });

    test('a legacy save survives a round trip through the new store', () async {
      // The migration path end to end: an old install's JSON, loaded, played,
      // saved, and reloaded.
      SharedPreferences.setMockInitialValues({
        'qbit_word_progress_v1': '{"a":{"box":4,"seen":9,"correct":8,"due":1},'
            '"b":{"box":0,"seen":0,"correct":0,"due":0}}',
      });
      final s = ProgressStore();
      await s.load();
      expect(s.wordCount, 2);
      expect(s.loadWarnings, isEmpty, reason: 'a migration is not a failure');
      expect(s.progressFor('a').stability, closeTo(3.0, 1e-9));

      await s.recordAnswer('a', true, 1770000000000, clockLeft: 0.5);
      await s.flush();

      final again = ProgressStore();
      await again.load();
      expect(again.progressFor('a').seen, 10);
      expect(again.progressFor('a').stability, greaterThan(3.0));
      expect(again.progressFor('a').state, SrsState.review);
    });
  });
}
