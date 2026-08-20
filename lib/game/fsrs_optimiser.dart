/// Fits the FSRS-5 weights to one learner's own review history.
///
/// WHAT THIS IS FOR. Qulex ships the published FSRS-5 defaults, fitted across
/// roughly 20,000 Anki collections. They are a large improvement on Leitner
/// boxes and they are still a stranger's memory: they describe the average of
/// twenty thousand people, and nobody is the average of twenty thousand people.
/// Anki retrains against your own history and gets measurably better at
/// predicting when YOU will forget. This is that, for Qulex.
///
/// HOW FITTING WORKS. FSRS is a model that, given a card's history and a set of
/// weights, predicts the probability you will recall it at the next review. So
/// the fit is ordinary supervised learning:
///
///   1. Replay every card's reviews in order under a candidate set of weights,
///      reconstructing stability and difficulty exactly as the scheduler would.
///   2. At each review, the model predicts R — the chance of recall. What
///      actually happened is known: 1 for a pass, 0 for a lapse.
///   3. Score the weights by LOG LOSS over every prediction. Lower is better.
///   4. Walk downhill.
///
/// Gradient descent, with the gradient taken NUMERICALLY rather than
/// analytically. FSRS's derivatives are miserable to write by hand and easy to
/// get subtly wrong; a wrong analytic gradient produces a fit that looks like
/// it is working and converges to nonsense. Central differences cost 38 extra
/// replays per step and are impossible to get wrong. A replay over a few
/// thousand reviews is milliseconds, so the whole fit is a second or two on a
/// phone — a price worth paying for a derivation nobody has to check.
///
/// WHAT PROTECTS THE LEARNER. Three things, because a bad fit is worse than no
/// fit — it degrades scheduling silently, and the learner has no way to know:
///
///   * A THRESHOLD. Below [ReviewLog.fitThreshold] reviews there is not enough
///     signal, and fitting produces confident nonsense.
///   * A HOLDOUT. The last fifth of the history is never trained on. The fit is
///     only accepted if it beats the defaults on data it has never seen, which
///     is what separates learning from memorising.
///   * BOUNDS. Every weight is clamped to a range the model is defined over.
///     An unclamped fit will happily propose a negative stability.
///
/// If any of those fail, the defaults stay. Declining to personalise is a
/// perfectly good outcome and the code says so out loud rather than shipping a
/// worse scheduler than it started with.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../data/review_log.dart';
import 'srs.dart';

/// The outcome of a fitting run.
class FitResult {
  /// The fitted weights, or null when the defaults were kept.
  final List<double>? weights;

  /// Log loss on the holdout under the DEFAULT weights.
  final double baselineLoss;

  /// Log loss on the holdout under the fitted weights.
  final double fittedLoss;

  /// Reviews actually used (after dropping cards with too little history).
  final int reviewsUsed;

  /// Plain-language reason the defaults were kept, or null on success.
  final String? declined;

  const FitResult({
    this.weights,
    required this.baselineLoss,
    required this.fittedLoss,
    required this.reviewsUsed,
    this.declined,
  });

  bool get improved => weights != null;

  /// How much better the fit predicts this learner, as a percentage of the
  /// baseline loss. Presented to nobody as an accuracy figure — it is a
  /// relative improvement in a loss, not "23% better memory".
  double get improvementPercent =>
      baselineLoss <= 0 ? 0 : (baselineLoss - fittedLoss) / baselineLoss * 100;
}

class FsrsOptimiser {
  const FsrsOptimiser._();

  /// Lower and upper bound for each of the 19 weights.
  ///
  /// Taken from the reference implementation's clamps. These are not style
  /// preferences: outside them the model is undefined — a negative initial
  /// stability, a difficulty term that inverts — and an unconstrained optimiser
  /// walks straight out of the valid region on its way downhill.
  static const List<(double, double)> bounds = [
    (0.001, 100.0), // w0  S0 again
    (0.001, 100.0), // w1  S0 hard
    (0.001, 100.0), // w2  S0 good
    (0.001, 100.0), // w3  S0 easy
    (1.0, 10.0), //    w4  D0 base
    (0.001, 4.0), //   w5  D0 curve
    (0.001, 4.0), //   w6  D delta
    (0.0, 0.75), //    w7  mean reversion
    (0.0, 4.5), //     w8  gain scale
    (0.0, 0.8), //     w9  saturation
    (0.001, 3.5), //   w10 retrievability bonus
    (0.001, 5.0), //   w11 post-lapse scale
    (0.001, 0.25), //  w12 post-lapse difficulty
    (0.001, 0.9), //   w13 post-lapse stability
    (0.0, 4.0), //     w14 post-lapse retrievability
    (0.0, 1.0), //     w15 hard penalty
    (1.0, 6.0), //     w16 easy bonus
    (0.0, 2.0), //     w17 short-term scale
    (-0.8, 0.8), //    w18 short-term offset
  ];

  /// Fraction of the history held back to judge the fit on.
  static const double holdoutFraction = 0.2;

  static const int maxSteps = 60;
  static const double learningRate = 0.02;
  static const double _epsilon = 1e-4;

  /// Fits [log]'s history, or explains why it didn't.
  ///
  /// Pure and synchronous over an already-read list, so it can be tested
  /// without a filesystem and moved to an isolate without restructuring.
  static FitResult fit(List<ReviewRecord> history) {
    // The threshold lives here as well as in the UI. Settings gates the button
    // on it, but fit() is a public function on a class anyone can call, and
    // fitting nineteen parameters to eighty reviews produces confident
    // nonsense rather than an error.
    if (history.length < ReviewLog.fitThreshold) {
      return FitResult(
          baselineLoss: 0,
          fittedLoss: 0,
          reviewsUsed: history.length,
          declined: 'Needs at least ${ReviewLog.fitThreshold} reviews; '
              'there are ${history.length}.');
    }
    final cards = _byCard(history);
    if (cards.isEmpty) {
      return const FitResult(
          baselineLoss: 0,
          fittedLoss: 0,
          reviewsUsed: 0,
          declined: 'No review history yet.');
    }

    // Split by CARD, not by review. Splitting mid-card would let the training
    // set see a card's early reviews and the holdout its later ones, which is
    // leakage: the model would be judged on cards it had already been shaped
    // by, and every fit would look like an improvement.
    final ids = cards.keys.toList()..sort();
    final cut = math.max(1, ((1 - holdoutFraction) * ids.length).floor());
    final train = [for (final id in ids.take(cut)) cards[id]!];
    final holdout = [for (final id in ids.skip(cut)) cards[id]!];
    final used = history.length;

    if (holdout.isEmpty || train.isEmpty) {
      return FitResult(
          baselineLoss: 0,
          fittedLoss: 0,
          reviewsUsed: used,
          declined: 'Not enough distinct words to judge a fit honestly.');
    }

    final baseline = _loss(holdout, Fsrs.w);
    if (!baseline.isFinite || baseline == 0) {
      return FitResult(
          baselineLoss: 0,
          fittedLoss: 0,
          reviewsUsed: used,
          declined: 'History has no gradable reviews in it.');
    }

    var w = List<double>.from(Fsrs.w);
    var trainLoss = _loss(train, w);

    for (var step = 0; step < maxSteps; step++) {
      final grad = _gradient(train, w);
      final next = List<double>.from(w);
      var moved = false;
      for (var i = 0; i < next.length; i++) {
        final (lo, hi) = bounds[i];
        final v = (next[i] - learningRate * grad[i]).clamp(lo, hi);
        if ((v - next[i]).abs() > 1e-9) moved = true;
        next[i] = v;
      }
      if (!moved) break;
      final nextLoss = _loss(train, next);
      // Plain backtracking: a step that makes things worse is not taken, and
      // the run stops rather than bouncing. With 19 coupled parameters and a
      // fixed rate, overshoot is the normal failure and this is the cheapest
      // honest guard against it.
      if (!nextLoss.isFinite || nextLoss >= trainLoss) break;
      w = next;
      trainLoss = nextLoss;
    }

    final fitted = _loss(holdout, w);
    if (!fitted.isFinite || fitted >= baseline) {
      return FitResult(
        baselineLoss: baseline,
        fittedLoss: fitted.isFinite ? fitted : baseline,
        reviewsUsed: used,
        declined: 'The fitted parameters were no better than the defaults on '
            'words they had not seen, so the defaults were kept.',
      );
    }

    return FitResult(
      weights: w,
      baselineLoss: baseline,
      fittedLoss: fitted,
      reviewsUsed: used,
    );
  }

  /// Replays [card] under [w] and returns the final (stability, difficulty).
  ///
  /// Exists only so a test can prove this file's copy of the model still agrees
  /// with the scheduler's. That agreement is the one thing keeping the
  /// duplication above safe.
  @visibleForTesting
  static (double, double) debugReplay(List<ReviewRecord> card, List<double> w) {
    double? s;
    double? d;
    int? last;
    for (final r in card) {
      final st = _step(s, d, last, r, w);
      s = st.$1;
      d = st.$2;
      last = r.atMillis;
    }
    return (s ?? 0, d ?? 0);
  }

  // ---------------------------------------------------------------------------

  static Map<String, List<ReviewRecord>> _byCard(List<ReviewRecord> history) {
    final out = <String, List<ReviewRecord>>{};
    for (final r in history) {
      (out[r.wordId] ??= <ReviewRecord>[]).add(r);
    }
    // A card seen once has no prediction to score: the first sighting is where
    // stability comes FROM, not something the model forecast.
    out.removeWhere((_, v) => v.length < 2);
    for (final v in out.values) {
      v.sort((a, b) => a.atMillis.compareTo(b.atMillis));
    }
    return out;
  }

  /// Mean log loss of the model's recall predictions across every card.
  ///
  /// Replays each card exactly as the scheduler would have, which is what makes
  /// this a fit of the real model rather than of a convenient approximation.
  static double _loss(List<List<ReviewRecord>> cards, List<double> w) {
    var total = 0.0;
    var n = 0;
    for (final card in cards) {
      double? s;
      double? d;
      int? last;
      for (final r in card) {
        final passed = r.grade != Grade.again;
        if (s != null && d != null && last != null) {
          final elapsedDays = (r.atMillis - last) / 86400000.0;
          final rr = _retrievability(elapsedDays, s, w);
          // Clamped away from 0 and 1: log(0) is infinite, and one surprising
          // review would otherwise dominate the entire fit.
          final pr = rr.clamp(1e-6, 1 - 1e-6);
          total += passed ? -math.log(pr) : -math.log(1 - pr);
          n++;
        }
        final st = _step(s, d, last, r, w);
        s = st.$1;
        d = st.$2;
        last = r.atMillis;
      }
    }
    return n == 0 ? double.infinity : total / n;
  }

  static List<double> _gradient(List<List<ReviewRecord>> cards, List<double> w) {
    final g = List<double>.filled(w.length, 0);
    for (var i = 0; i < w.length; i++) {
      final (lo, hi) = bounds[i];
      final h = math.max(_epsilon, w[i].abs() * _epsilon);
      final up = List<double>.from(w)..[i] = (w[i] + h).clamp(lo, hi);
      final down = List<double>.from(w)..[i] = (w[i] - h).clamp(lo, hi);
      final span = up[i] - down[i];
      if (span == 0) continue;
      final lu = _loss(cards, up);
      final ld = _loss(cards, down);
      if (!lu.isFinite || !ld.isFinite) continue;
      g[i] = (lu - ld) / span;
    }
    return g;
  }

  // --- the model, parameterised by w rather than by Fsrs.w --------------------
  //
  // Deliberately duplicated from Fsrs rather than reached through it. Fsrs
  // reads its constants from a static list; fitting needs to evaluate the same
  // arithmetic under CANDIDATE weights thousands of times, and threading a
  // parameter vector through the scheduler's public API would complicate the
  // shipping path for the benefit of the experimental one. fsrs_optimiser_test
  // asserts the two agree on the defaults, which is what keeps the duplication
  // honest.

  static double _factor(List<double> w) => math.pow(0.9, 1 / Fsrs.decay) - 1;

  static double _retrievability(double t, double s, List<double> w) =>
      math.pow(1 + _factor(w) * math.max(t, 0) / s, Fsrs.decay).toDouble();

  static (double, double) _step(
      double? s, double? d, int? last, ReviewRecord r, List<double> w) {
    final g = r.grade.value;
    if (s == null || d == null || last == null) {
      return (
        math.max(w[g - 1], 0.1),
        (w[4] - math.exp(w[5] * (g - 1)) + 1).clamp(1.0, 10.0),
      );
    }
    final elapsed = (r.atMillis - last) / 86400000.0;
    final nd = _nextDifficulty(d, g, w);
    if (elapsed < 1.0) {
      return (
        math.max(s * math.exp(w[17] * (g - 3 + w[18])), Fsrs.minStability),
        nd
      );
    }
    final rr = _retrievability(elapsed, s, w);
    final ns = r.grade == Grade.again
        ? _forget(d, s, rr, w)
        : _recall(d, s, rr, g, w);
    return (ns, nd);
  }

  static double _nextDifficulty(double d, int g, List<double> w) {
    final delta = -(w[6] * (g - 3));
    final damped = d + (10.0 - d) * delta / 9.0;
    final d0Easy = (w[4] - math.exp(w[5] * 3) + 1).clamp(1.0, 10.0);
    return (w[7] * d0Easy + (1 - w[7]) * damped).clamp(1.0, 10.0);
  }

  static double _recall(
      double d, double s, double r, int g, List<double> w) {
    final hard = g == 2 ? w[15] : 1.0;
    final easy = g == 4 ? w[16] : 1.0;
    final v = s *
        (1 +
            math.exp(w[8]) *
                (11 - d) *
                math.pow(s, -w[9]) *
                (math.exp(w[10] * (1 - r)) - 1) *
                hard *
                easy);
    return v.isFinite ? math.max(v, Fsrs.minStability) : Fsrs.minStability;
  }

  static double _forget(double d, double s, double r, List<double> w) {
    final long = w[11] *
        math.pow(d, -w[12]) *
        (math.pow(s + 1, w[13]) - 1) *
        math.exp((1 - r) * w[14]);
    final ceiling = s / math.exp(w[17] * w[18]);
    final v = math.min(long.toDouble(), ceiling);
    return v.isFinite ? math.max(v, Fsrs.minStability) : Fsrs.minStability;
  }
}
