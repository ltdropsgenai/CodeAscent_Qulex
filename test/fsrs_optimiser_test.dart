import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:qulex/data/review_log.dart';
import 'package:qulex/game/fsrs_optimiser.dart';
import 'package:qulex/game/srs.dart';

/// Fitting is the part of this app most able to fail silently: a bad fit still
/// produces nineteen plausible-looking numbers, still schedules reviews, and is
/// wrong in a way no learner could ever notice. So these tests are mostly about
/// the guards, and one of them is about whether the thing works at all.
void main() {
  const day = 86400000;

  ReviewRecord rec(String id, int at, Grade g, [String phase = 'r']) =>
      ReviewRecord(wordId: id, atMillis: at, grade: g, phase: phase);

  /// A synthetic learner whose forgetting follows FSRS with a KNOWN parameter
  /// vector, so the fit has a right answer to be judged against.
  ///
  /// Deterministic: a seeded generator, because a flaky optimiser test is worse
  /// than none — it trains everyone to re-run until green.
  List<ReviewRecord> synthetic({
    required List<double> truth,
    int cards = 120,
    int reviewsPerCard = 8,
    int seed = 7,
  }) {
    final rng = math.Random(seed);
    final out = <ReviewRecord>[];
    final factor = math.pow(0.9, 1 / Fsrs.decay) - 1;
    for (var c = 0; c < cards; c++) {
      var t = 1770000000000 + c * 3600000;
      double? s;
      var d = 5.0;
      int? last;
      for (var i = 0; i < reviewsPerCard; i++) {
        Grade g;
        if (s == null) {
          g = Grade.good;
          s = math.max(truth[g.value - 1], 0.1);
        } else {
          // The gap the learner actually waited, which is also the gap the log
          // will show. The first version of this drew a FRESH random interval
          // here while advancing `t` by a different one, so every outcome was
          // generated from a delay that appears nowhere in the history the
          // optimiser reads. Labels that do not match their own features are
          // noise, and a fit that improves on noise (see the coin-flip test)
          // proves nothing about a fit on a learner.
          final elapsed = (t - last!) / 86400000.0;
          final r = math.pow(1 + factor * elapsed / s, Fsrs.decay).toDouble();
          // Recall happens with probability r under the TRUE parameters.
          final passed = rng.nextDouble() < r;
          g = passed ? Grade.good : Grade.again;
          s = passed
              ? s *
                  (1 +
                      math.exp(truth[8]) *
                          (11 - d) *
                          math.pow(s, -truth[9]) *
                          (math.exp(truth[10] * (1 - r)) - 1))
              : math.max(
                  truth[11] *
                      math.pow(d, -truth[12]) *
                      (math.pow(s + 1, truth[13]) - 1) *
                      math.exp((1 - r) * truth[14]),
                  0.01);
          d = (d + (10.0 - d) * (-(truth[6] * (g.value - 3))) / 9.0)
              .clamp(1.0, 10.0);
        }
        out.add(rec('w_$c', t, g));
        last = t;
        t += day * (1 + rng.nextInt(3));
      }
    }
    return out;
  }

  group('refusing to fit', () {
    test('an empty history', () {
      final r = FsrsOptimiser.fit(const []);
      expect(r.improved, isFalse);
      expect(r.declined, isNotNull);
      expect(r.weights, isNull);
    });

    test('a history where every card was seen exactly once', () {
      // A first sighting is where stability comes FROM. There is no prediction
      // to score, so there is nothing to fit.
      final h = [
        for (var i = 0; i < 500; i++)
          rec('w_$i', 1770000000000 + i * day, Grade.good, 'n')
      ];
      final r = FsrsOptimiser.fit(h);
      expect(r.improved, isFalse);
      expect(r.declined, isNotNull);
    });

    test('a history with too few distinct words to hold any back', () {
      final h = [
        for (var i = 0; i < 40; i++)
          rec('only_word', 1770000000000 + i * day, Grade.good)
      ];
      final r = FsrsOptimiser.fit(h);
      expect(r.improved, isFalse);
    });

    test('a history below the review threshold', () {
      // The Settings button is gated on this too, but fit() is public and
      // fitting nineteen parameters to eighty reviews produces confident
      // nonsense rather than an error.
      final h = [
        for (var i = 0; i < ReviewLog.fitThreshold - 1; i++)
          rec('w_${i % 40}', 1770000000000 + i * day, Grade.good)
      ];
      final r = FsrsOptimiser.fit(h);
      expect(r.improved, isFalse);
      expect(r.declined, contains('${ReviewLog.fitThreshold}'));
    });

    test('a learner whose answers are pure coin flips is fitted honestly', () {
      // This started life asserting that a fit on noise must NOT improve, on
      // the assumption that any improvement meant overfitting. It reported a
      // 14% improvement, and the assumption was wrong: for a learner whose
      // recall is independent of everything the model knows, "predict about a
      // coin flip" genuinely IS a better prediction than the defaults' rising
      // and falling R, and the holdout confirms it on cards the fit never saw.
      //
      // So the honest assertion is not "no improvement". It is that whatever
      // comes back is a real held-out improvement and stays inside the bounds —
      // which is exactly what protects a learner whose data is unusual rather
      // than merely noisy.
      final rng = math.Random(11);
      var t = 1770000000000;
      final h = <ReviewRecord>[];
      for (var c = 0; c < 120; c++) {
        for (var i = 0; i < 6; i++) {
          h.add(rec('w_$c', t, rng.nextBool() ? Grade.good : Grade.again));
          t += day;
        }
      }
      final r = FsrsOptimiser.fit(h);
      if (r.improved) {
        expect(r.fittedLoss, lessThan(r.baselineLoss));
        for (var i = 0; i < r.weights!.length; i++) {
          final (lo, hi) = FsrsOptimiser.bounds[i];
          expect(r.weights![i], inInclusiveRange(lo, hi));
        }
      } else {
        expect(r.declined, isNotNull);
      }
    });
  });

  group('fitting', () {
    test('beats the defaults on a learner who is not the average', () {
      // The whole premise. This learner forgets faster than the FSRS defaults
      // assume; if fitting cannot beat a stranger's parameters here, the
      // feature has no reason to exist.
      final truth = List<double>.from(Fsrs.w)
        ..[8] = Fsrs.w[8] * 0.55 // gains much less stability per review
        ..[10] = Fsrs.w[10] * 0.6;
      final history = synthetic(truth: truth);

      final r = FsrsOptimiser.fit(history);
      expect(r.improved, isTrue,
          reason: 'declined with: ${r.declined}');
      expect(r.fittedLoss, lessThan(r.baselineLoss));
      expect(r.improvementPercent, greaterThan(0));
    });

    test('the fit generalises to a fresh history from the same learner', () {
      // fit()'s own holdout is still data the optimiser chose the split for.
      // This is the stronger claim: simulate the SAME learner again from a
      // different seed, and ask whether the fitted weights predict that history
      // better than the published defaults do. Nothing in this second history
      // was seen during training or during the accept/reject decision.
      final truth = List<double>.from(Fsrs.w)
        ..[8] = Fsrs.w[8] * 0.55
        ..[10] = Fsrs.w[10] * 0.6;
      final r = FsrsOptimiser.fit(synthetic(truth: truth, seed: 7));
      expect(r.improved, isTrue, reason: 'declined with: ${r.declined}');

      final fresh = synthetic(truth: truth, seed: 4242, cards: 90);
      final withDefaults = FsrsOptimiser.debugLoss(fresh, Fsrs.w);
      final withFit = FsrsOptimiser.debugLoss(fresh, r.weights!);
      expect(withFit, lessThan(withDefaults),
          reason: 'the fit only beat its own holdout, not the learner');
    });

    test('a learner who IS the average is left alone or barely moved', () {
      // The mirror of the premise. When the defaults already describe someone,
      // there is nothing to win, and a fit that claims a large improvement here
      // is fitting noise. Either outcome is acceptable; a big number is not.
      final r = FsrsOptimiser.fit(synthetic(truth: Fsrs.w, seed: 21));
      if (r.improved) {
        expect(r.improvementPercent, lessThan(12),
            reason: 'nothing to learn from a learner the defaults already fit');
      }
    });

    test('every fitted weight stays inside the model bounds', () {
      final truth = List<double>.from(Fsrs.w)..[8] = Fsrs.w[8] * 0.5;
      final r = FsrsOptimiser.fit(synthetic(truth: truth));
      expect(r.weights, isNotNull);
      for (var i = 0; i < r.weights!.length; i++) {
        final (lo, hi) = FsrsOptimiser.bounds[i];
        expect(r.weights![i], inInclusiveRange(lo, hi), reason: 'w$i');
        expect(r.weights![i].isFinite, isTrue, reason: 'w$i');
      }
    });

    test('is deterministic — the same history fits the same weights', () {
      final h = synthetic(truth: List<double>.from(Fsrs.w)..[8] = 0.9);
      final a = FsrsOptimiser.fit(h);
      final b = FsrsOptimiser.fit(h);
      expect(a.weights, b.weights);
      expect(a.fittedLoss, b.fittedLoss);
    });

    test('leaves the live scheduler alone', () {
      // fit() computes; adopting is a separate, explicit act. If fitting itself
      // mutated Fsrs, a declined fit would still have changed the schedule.
      final before = List<double>.from(Fsrs.p);
      FsrsOptimiser.fit(synthetic(truth: List<double>.from(Fsrs.w)..[8] = 0.8));
      expect(Fsrs.p, before);
      expect(Fsrs.isPersonalised, isFalse);
    });
  });

  group('adopting a fit', () {
    tearDown(Fsrs.useDefaults);

    test('changes what the scheduler does', () {
      final before = Fsrs.recallStability(5.0, 10.0, 0.9, Grade.good);
      final slower = List<double>.from(Fsrs.w)..[8] = Fsrs.w[8] * 0.5;
      expect(Fsrs.usePersonalised(slower), isTrue);
      expect(Fsrs.isPersonalised, isTrue);
      final after = Fsrs.recallStability(5.0, 10.0, 0.9, Grade.good);
      expect(after, lessThan(before),
          reason: 'a learner fitted as forgetting faster must be reviewed '
              'sooner, or adopting the fit did nothing');
    });

    test('refuses a vector of the wrong length', () {
      expect(Fsrs.usePersonalised(const [1, 2, 3]), isFalse);
      expect(Fsrs.isPersonalised, isFalse);
    });

    test('refuses a vector containing a non-finite value', () {
      final bad = List<double>.from(Fsrs.w)..[3] = double.nan;
      expect(Fsrs.usePersonalised(bad), isFalse);
      final worse = List<double>.from(Fsrs.w)..[3] = double.infinity;
      expect(Fsrs.usePersonalised(worse), isFalse);
      expect(Fsrs.isPersonalised, isFalse);
    });

    test('reverts cleanly', () {
      Fsrs.usePersonalised(List<double>.from(Fsrs.w)..[8] = 0.7);
      expect(Fsrs.isPersonalised, isTrue);
      Fsrs.useDefaults();
      expect(Fsrs.isPersonalised, isFalse);
      expect(Fsrs.p, Fsrs.w);
    });
  });

  group('the optimiser and the scheduler agree', () {
    test('on the defaults, the replay matches Fsrs exactly', () {
      // The optimiser reimplements the model so it can evaluate candidate
      // weights. That duplication is only safe while the two agree, and this is
      // what keeps them honest: if someone changes a formula in srs.dart and
      // not here, a fit would optimise the wrong model and every test above
      // would still pass.
      final probe = <ReviewRecord>[
        rec('w', 1770000000000, Grade.good, 'n'),
        rec('w', 1770000000000 + 3 * day, Grade.good),
        rec('w', 1770000000000 + 12 * day, Grade.again),
        rec('w', 1770000000000 + 13 * day, Grade.good),
      ];
      // Replay by hand through the SHIPPING scheduler.
      double? s;
      double? d;
      int? last;
      for (final r in probe) {
        final elapsed =
            last == null ? null : (r.atMillis - last) / 86400000.0;
        final out = Fsrs.review(
          state: s == null ? SrsState.fresh : SrsState.review,
          step: -1,
          stability: s ?? 0,
          difficulty: d ?? 0,
          elapsedDays: elapsed,
          grade: r.grade,
          desiredRetention: 0.9,
          fuzzSeed: 'x',
        );
        s = out.stability;
        d = out.difficulty;
        last = r.atMillis;
      }
      final viaOptimiser = FsrsOptimiser.debugReplay(probe, Fsrs.w);
      expect(viaOptimiser.$1, closeTo(s!, 1e-9),
          reason: 'stability drifted between the two implementations');
      expect(viaOptimiser.$2, closeTo(d!, 1e-9),
          reason: 'difficulty drifted between the two implementations');
    });
  });
}
