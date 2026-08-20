/// FSRS-5 spaced repetition.
///
/// This replaces the Leitner box ladder Qulex shipped with. The boxes were
/// honest but crude: every word in box 3 came back in exactly one day whether
/// it was `cat` or `catachresis`, and a word missed four times running was
/// treated identically to one never seen. FSRS models each word with two
/// numbers instead of one bucket:
///
///  * STABILITY (S), in days — how long until recall probability decays to 90%.
///  * DIFFICULTY (D), 1..10 — how much a correct answer buys you for this
///    particular word. Hard words gain stability more slowly, forever.
///
/// and a third derived at review time:
///
///  * RETRIEVABILITY (R), 0..1 — the modelled probability you would recall it
///    right now, given S and how long it has been. Reviewing a word you were
///    about to forget is worth more than reviewing one you saw an hour ago, and
///    the stability update says so explicitly.
///
/// WHY THIS ONE. FSRS is what Anki ships as its default scheduler, so it is
/// both the state of the art in this product category and the thing Qulex was
/// visibly behind on. The parameter vector below is the published FSRS-5
/// default, fitted on roughly 20k real Anki collections; it is what a learner
/// gets before there is enough of their own history to retrain on.
///
/// FIDELITY. The formulas here are a direct port of the reference
/// implementation (py-fsrs 4.1.1, `fsrs/fsrs.py`), including the learning and
/// relearning step machine, the mean-reverting difficulty update, the
/// short-term same-day stability path and the post-lapse clamp. There are
/// exactly two deliberate deviations and both are commented where they happen:
/// the grade mapping (Qulex has no four-button grading UI — see [gradeFor])
/// and deterministic interval fuzz (see [_fuzz]).
///
/// See fsrs_test.dart, which checks this port against values printed from the
/// reference implementation rather than against my own arithmetic.
library;

import 'dart:math' as math;

/// How well a word was recalled. FSRS is defined over these four grades.
enum Grade {
  again(1),
  hard(2),
  good(3),
  easy(4);

  const Grade(this.value);
  final int value;
}

/// Where a word sits in the learning/review cycle.
enum SrsState {
  /// Brand new; never answered.
  fresh,

  /// Being introduced — walking the [Fsrs.learningSteps].
  learning,

  /// Graduated; intervals now come from stability.
  review,

  /// Was in review and got missed — walking [Fsrs.relearningSteps] back up.
  relearning,
}

/// The FSRS-5 model. Pure functions over (stability, difficulty, grade).
class Fsrs {
  /// Published FSRS-5 default weights. Do not reorder — every formula below
  /// indexes this by position.
  static const List<double> w = [
    0.40255, // w0  initial stability, Again
    1.18385, // w1  initial stability, Hard
    3.173, //   w2  initial stability, Good
    15.69105, // w3  initial stability, Easy
    7.1949, //  w4  initial difficulty base
    0.5345, //  w5  initial difficulty curve
    1.4604, //  w6  difficulty delta per grade
    0.0046, //  w7  mean reversion toward D0(Easy)
    1.54575, // w8  stability gain scale
    0.1192, //  w9  stability saturation exponent
    1.01925, // w10 retrievability bonus
    1.9395, //  w11 post-lapse scale
    0.11, //    w12 post-lapse difficulty exponent
    0.29605, // w13 post-lapse stability exponent
    2.2698, //  w14 post-lapse retrievability term
    0.2315, //  w15 hard penalty
    2.9898, //  w16 easy bonus
    0.51655, // w17 short-term scale
    0.6621, //  w18 short-term offset
  ];

  /// The forgetting curve's shape. DECAY = -0.5 is FSRS-5's power law; FACTOR
  /// is derived from it so that R = 0.9 exactly when elapsed == stability,
  /// which is what makes "stability" mean "days until 90% recall".
  static const double decay = -0.5;
  static final double factor = math.pow(0.9, 1 / decay) - 1; // 19/81

  /// The steps a new word walks before it gets a real interval. These are the
  /// old Leitner boxes 0 and 1, kept deliberately: a vocabulary game wants a
  /// missed word back inside the same round, and FSRS's day-granular intervals
  /// cannot express that. py-fsrs ships the same two defaults.
  static const List<Duration> learningSteps = [
    Duration(minutes: 1),
    Duration(minutes: 10),
  ];

  /// Same idea for a word that was known and got missed.
  static const List<Duration> relearningSteps = [Duration(minutes: 10)];

  /// Longest interval we will ever schedule.
  ///
  /// Anki's ceiling is ten years. Qulex's is one, deliberately: a vocabulary
  /// game that will not show you a word again for a decade has not scheduled
  /// it, it has dropped it — and the model saturates there faster than you
  /// would expect, in about six fast correct answers. Qulex already has an
  /// explicit action for "I know this, stop showing me" (markKnown), so the
  /// scheduler does not need to express it by accident.
  static const int maximumIntervalDays = 365;

  static const double minStability = 0.001;

  static double _clampD(double d) => d.clamp(1.0, 10.0);
  static double _clampS(double s) =>
      s.isFinite ? math.max(s, minStability) : minStability;

  // ---------------------------------------------------------------------------
  // The model
  // ---------------------------------------------------------------------------

  /// Probability of recalling a word with stability [s] after [elapsedDays].
  static double retrievability(double elapsedDays, double s) {
    if (s <= 0) return 0;
    final t = elapsedDays < 0 ? 0.0 : elapsedDays;
    return math.pow(1 + factor * t / s, decay).toDouble();
  }

  /// Days until recall probability falls to [desiredRetention].
  ///
  /// At the default 0.9 this returns exactly [s] — the identity that gives
  /// stability its units.
  static double intervalDays(double s, double desiredRetention) {
    final r = desiredRetention.clamp(0.70, 0.99);
    return (s / factor) * (math.pow(r, 1 / decay) - 1);
  }

  static double initialStability(Grade g) => math.max(w[g.value - 1], 0.1);

  static double initialDifficulty(Grade g) =>
      _clampD(w[4] - math.exp(w[5] * (g.value - 1)) + 1);

  /// Difficulty after a review, with linear damping and mean reversion toward
  /// D0(Easy). The damping is what stops a run of misses pinning a word at 10
  /// forever; the reversion is what stops difficulty drifting on a long tail of
  /// easy answers.
  static double nextDifficulty(double d, Grade g) {
    final deltaD = -(w[6] * (g.value - 3));
    final damped = d + (10.0 - d) * deltaD / 9.0;
    return _clampD(w[7] * initialDifficulty(Grade.easy) + (1 - w[7]) * damped);
  }

  /// Stability after a review on the same day. Deliberately small: seeing a
  /// word twice in one session is worth much less than seeing it twice a week
  /// apart, and a scheduler that does not model this can be farmed by drilling.
  static double shortTermStability(double s, Grade g) =>
      _clampS(s * math.exp(w[17] * (g.value - 3 + w[18])));

  /// Stability after a successful review.
  static double recallStability(double d, double s, double r, Grade g) {
    final hardPenalty = g == Grade.hard ? w[15] : 1.0;
    final easyBonus = g == Grade.easy ? w[16] : 1.0;
    return _clampS(s *
        (1 +
            math.exp(w[8]) *
                (11 - d) *
                math.pow(s, -w[9]) *
                (math.exp(w[10] * (1 - r)) - 1) *
                hardPenalty *
                easyBonus));
  }

  /// Stability after a lapse. Clamped so a lapse can never *increase*
  /// stability — the second term is FSRS-5's short-term-consistent ceiling.
  static double forgetStability(double d, double s, double r) {
    final longTerm = w[11] *
        math.pow(d, -w[12]) *
        (math.pow(s + 1, w[13]) - 1) *
        math.exp((1 - r) * w[14]);
    final ceiling = s / math.exp(w[17] * w[18]);
    return _clampS(math.min(longTerm.toDouble(), ceiling));
  }

  // ---------------------------------------------------------------------------
  // Grade mapping — DEVIATION 1 from the reference implementation
  // ---------------------------------------------------------------------------

  /// FSRS expects a learner to self-grade on four buttons. Qulex has no such UI
  /// and is never going to grow one: it is a game with a clock, and asking "how
  /// well did you know that?" after every question would wreck the pace.
  ///
  /// So the grade is inferred. Correctness gives Again vs. the rest; the
  /// fraction of the clock still unspent when the answer landed separates Hard
  /// / Good / Easy. That is a real confidence signal — hesitating over three
  /// options for six of eight seconds is exactly what "Hard" means — and it is
  /// free, because the countdown already exists.
  ///
  /// [clockLeft] is remaining/total, or null in untimed modes (Review), where
  /// there is no signal and everything correct is Good.
  static Grade gradeFor({required bool correct, double? clockLeft}) {
    if (!correct) return Grade.again;
    if (clockLeft == null) return Grade.good;
    final f = clockLeft.clamp(0.0, 1.0);
    // Thresholds are deliberately mean at the top. Easy carries a 3x stability
    // bonus in FSRS, and on a three-option multiple-choice question with an
    // eight-second clock, "answered in under four seconds" is achievable by
    // guessing. Reserve Easy for the first quarter of the clock — instant
    // recognition — and let everything else be an ordinary Good.
    if (f >= 0.75) return Grade.easy;
    if (f >= 0.25) return Grade.good;
    return Grade.hard; // went nearly to the buzzer
  }

  // ---------------------------------------------------------------------------
  // Interval fuzz — DEVIATION 2
  // ---------------------------------------------------------------------------

  /// Spreads due dates so a big cohort of words learned in one session does not
  /// come back as a single wall on one later day.
  ///
  /// The reference implementation uses a random number. This uses a hash of the
  /// word id and its review count instead, so the schedule is a pure function
  /// of state: the same word answered the same way always lands on the same
  /// day, tests are deterministic, and re-running a migration twice cannot walk
  /// a due date. Same spread, no entropy.
  static double _fuzz(double days, String seed) {
    if (days < 2.5) return days;
    final f = days < 7.0
        ? 0.15
        : days < 20.0
            ? 0.10
            : 0.05;
    final span = days * f;
    var h = 0x811c9dc5;
    for (final c in seed.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
    }
    final unit = (h % 10000) / 10000.0; // 0..1, deterministic
    return math.max(1.0, days + span * (unit * 2 - 1));
  }

  /// The whole scheduler: given current state and an answer, produce the next
  /// state and the next due time.
  ///
  /// [elapsedDays] is time since the last review — null for a first sight.
  static SrsOutcome review({
    required SrsState state,
    required int step,
    required double stability,
    required double difficulty,
    required double? elapsedDays,
    required Grade grade,
    required double desiredRetention,
    required String fuzzSeed,
  }) {
    double s;
    double d;

    if (state == SrsState.fresh) {
      s = initialStability(grade);
      d = initialDifficulty(grade);
    } else if (elapsedDays != null && elapsedDays < 1.0) {
      // Same-day repeat: the cheap path, on purpose.
      s = shortTermStability(stability, grade);
      d = nextDifficulty(difficulty, grade);
    } else {
      final r = retrievability(elapsedDays ?? 0, stability);
      s = grade == Grade.again
          ? forgetStability(difficulty, stability, r)
          : recallStability(difficulty, stability, r, grade);
      d = nextDifficulty(difficulty, grade);
    }

    // --- where the word goes next -------------------------------------------
    SrsState nextState;
    int nextStep;
    Duration wait;

    Duration graduate() {
      final days = _fuzz(intervalDays(s, desiredRetention), fuzzSeed)
          .clamp(1.0, maximumIntervalDays.toDouble());
      return Duration(minutes: (days * 1440).round());
    }

    switch (state) {
      case SrsState.fresh:
      case SrsState.learning:
        switch (grade) {
          case Grade.again:
            nextState = SrsState.learning;
            nextStep = 0;
            wait = learningSteps[0];
          case Grade.hard:
            // Repeat the step you are on rather than losing ground; on the very
            // first step, split the difference to the next one.
            nextState = SrsState.learning;
            nextStep = step.clamp(0, learningSteps.length - 1);
            wait = step == 0 && learningSteps.length > 1
                ? Duration(
                    milliseconds: ((learningSteps[0].inMilliseconds +
                                learningSteps[1].inMilliseconds) /
                            2)
                        .round())
                : learningSteps[nextStep];
          case Grade.good:
            final advanced = step + 1;
            if (advanced >= learningSteps.length) {
              nextState = SrsState.review;
              nextStep = -1;
              wait = graduate();
            } else {
              nextState = SrsState.learning;
              nextStep = advanced;
              wait = learningSteps[advanced];
            }
          case Grade.easy:
            nextState = SrsState.review; // straight out of learning
            nextStep = -1;
            wait = graduate();
        }
      case SrsState.review:
        if (grade == Grade.again) {
          nextState = SrsState.relearning;
          nextStep = 0;
          wait = relearningSteps[0];
        } else {
          nextState = SrsState.review;
          nextStep = -1;
          wait = graduate();
        }
      case SrsState.relearning:
        switch (grade) {
          case Grade.again:
            nextState = SrsState.relearning;
            nextStep = 0;
            wait = relearningSteps[0];
          case Grade.hard:
            nextState = SrsState.relearning;
            nextStep = step.clamp(0, relearningSteps.length - 1);
            wait = relearningSteps[nextStep];
          case Grade.good:
          case Grade.easy:
            final advanced = step + 1;
            if (advanced >= relearningSteps.length || grade == Grade.easy) {
              nextState = SrsState.review;
              nextStep = -1;
              wait = graduate();
            } else {
              nextState = SrsState.relearning;
              nextStep = advanced;
              wait = relearningSteps[advanced];
            }
        }
    }

    return SrsOutcome(
      stability: s,
      difficulty: d,
      state: nextState,
      step: nextStep,
      wait: wait,
    );
  }

  // ---------------------------------------------------------------------------
  // Migration off the Leitner boxes
  // ---------------------------------------------------------------------------

  /// The intervals the old Leitner ladder used, in minutes, by box.
  static const List<int> legacyBoxMinutes = [1, 10, 60, 1440, 4320, 10080];

  /// Reconstructs an FSRS state from a Leitner box plus the word's history.
  ///
  /// Nobody's progress gets reset by this change. A box carries roughly one bit
  /// of information — how long until this is due — and at the default 90%
  /// retention "days until due" IS stability, so the old interval converts
  /// straight across. Difficulty is not in the old model at all, so it is
  /// estimated from the accuracy actually recorded on that word, falling back
  /// to D0(Good) for words with too little history to say anything.
  static ({double stability, double difficulty, SrsState state, int step})
      fromLegacyBox({
    required int box,
    required int seen,
    required int correct,
  }) {
    final b = box.clamp(0, legacyBoxMinutes.length - 1);

    // Boxes 0 and 1 were the sub-hour steps; they map onto the learning steps
    // they were modelled on rather than becoming absurdly small stabilities.
    if (b <= 1) {
      return (
        stability: initialStability(Grade.good),
        difficulty: _difficultyFromHistory(seen, correct),
        state: seen == 0 ? SrsState.fresh : SrsState.learning,
        step: b,
      );
    }

    return (
      stability: math.max(legacyBoxMinutes[b] / 1440.0, 0.1),
      difficulty: _difficultyFromHistory(seen, correct),
      state: SrsState.review,
      step: -1,
    );
  }

  /// D0(Good) nudged by measured accuracy. Below ~4 answers there is not enough
  /// signal to move off the default, and pretending otherwise would let one
  /// unlucky miss brand a word as permanently hard.
  static double _difficultyFromHistory(int seen, int correct) {
    final base = initialDifficulty(Grade.good);
    if (seen < 4) return base;
    final accuracy = (correct / seen).clamp(0.0, 1.0);
    // 100% accurate -> a little easier than default; 0% -> a lot harder.
    return _clampD(base + (0.8 - accuracy) * 6.0);
  }
}

/// The result of scheduling one answer.
class SrsOutcome {
  final double stability;
  final double difficulty;
  final SrsState state;
  final int step;
  final Duration wait;

  const SrsOutcome({
    required this.stability,
    required this.difficulty,
    required this.state,
    required this.step,
    required this.wait,
  });
}
