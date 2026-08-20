/// Per-word learning state (FSRS-5 spaced repetition) + the player profile.
/// Persisted as JSON via ProgressStore.
library;

import '../game/srs.dart';

class WordProgress {
  /// Days until recall probability decays to 90%. The core FSRS quantity.
  double stability;

  /// 1..10. How much a correct answer buys you for THIS word.
  double difficulty;

  /// Where the word sits in the learning/review cycle.
  SrsState state;

  /// Index into Fsrs.learningSteps / relearningSteps; -1 once graduated.
  int step;

  int seen;
  int correct;

  /// Times a graduated word was missed. Not used for scheduling — FSRS gets
  /// that from stability — but it is what "words you keep losing" is built on.
  int lapses;

  int dueAtMillis; // epoch ms when this word is next due for review
  int lastReviewMillis; // epoch ms of the last answer; 0 = never
  bool suspended; // user marked "known - stop showing"; excluded from decks

  WordProgress({
    this.stability = 0,
    this.difficulty = 0,
    this.state = SrsState.fresh,
    this.step = 0,
    this.seen = 0,
    this.correct = 0,
    this.lapses = 0,
    this.dueAtMillis = 0,
    this.lastReviewMillis = 0,
    this.suspended = false,
  });

  /// A word is "known" once the model expects it to survive three weeks.
  ///
  /// The old definition was "reached Leitner box 2", which meant one hour. That
  /// flattered the counter badly — a word answered right twice inside a single
  /// round counted as known. Three weeks of modelled stability is a claim the
  /// scheduler is actually willing to act on: it is the point where Qulex stops
  /// showing you the word for most of a month.
  static const double knownStabilityDays = 21.0;

  bool get isKnown =>
      state == SrsState.review && stability >= knownStabilityDays;

  Map<String, dynamic> toJson() => {
        's': stability,
        'd': difficulty,
        'st': state.index,
        'stp': step,
        'seen': seen,
        'correct': correct,
        if (lapses > 0) 'lap': lapses,
        'due': dueAtMillis,
        if (lastReviewMillis > 0) 'lr': lastReviewMillis,
        if (suspended) 'susp': true,
      };

  /// Reads both the FSRS shape above and the Leitner shape Qulex shipped before
  /// it.
  ///
  /// The old records are still on every existing installation, and there is no
  /// migration step or schema version anywhere in this app to hang a conversion
  /// off — so the conversion lives here, in the one function every stored word
  /// already passes through. A record written by the old build is recognised by
  /// the absence of 's' and the presence of 'box'; see Fsrs.fromLegacyBox for
  /// what it becomes and why nobody loses progress.
  factory WordProgress.fromJson(Map<String, dynamic> j) {
    final seen = (j['seen'] as num?)?.toInt() ?? 0;
    final correct = (j['correct'] as num?)?.toInt() ?? 0;
    final due = (j['due'] as num?)?.toInt() ?? 0;
    final suspended = (j['susp'] as bool?) ?? false;

    if (j['s'] == null && j['box'] != null) {
      final m = Fsrs.fromLegacyBox(
        box: (j['box'] as num).toInt(),
        seen: seen,
        correct: correct,
      );
      return WordProgress(
        stability: m.stability,
        difficulty: m.difficulty,
        state: m.state,
        step: m.step,
        seen: seen,
        correct: correct,
        lapses: 0, // the old model never recorded them
        dueAtMillis: due,
        // Unknown, and guessing would fake a same-day review. Zero means "no
        // elapsed time is derivable", which recordAnswer handles explicitly.
        lastReviewMillis: 0,
        suspended: suspended,
      );
    }

    final stateIndex = (j['st'] as num?)?.toInt() ?? 0;
    return WordProgress(
      stability: (j['s'] as num?)?.toDouble() ?? 0,
      difficulty: (j['d'] as num?)?.toDouble() ?? 0,
      state: SrsState.values[stateIndex.clamp(0, SrsState.values.length - 1)],
      step: (j['stp'] as num?)?.toInt() ?? 0,
      seen: seen,
      correct: correct,
      lapses: (j['lap'] as num?)?.toInt() ?? 0,
      dueAtMillis: due,
      lastReviewMillis: (j['lr'] as num?)?.toInt() ?? 0,
      suspended: suspended,
    );
  }
}

class PlayerProfile {
  int streak;
  int bestStreak;
  String lastPlayedYmd; // 'YYYY-MM-DD' local, or '' if never played
  int lifetimeSeen;
  int lifetimeCorrect;
  String dailyYmd; // date of last completed Daily Challenge
  int dailyScore;
  int dailyAccuracy;
  String newIntroYmd; // day the new-word intro counter belongs to
  int newIntroCount; // new (unseen) words introduced so far today
  int placementRank; // freqRank the learner reliably knows up to (0 = unplaced)

  PlayerProfile({
    this.streak = 0,
    this.bestStreak = 0,
    this.lastPlayedYmd = '',
    this.lifetimeSeen = 0,
    this.lifetimeCorrect = 0,
    this.dailyYmd = '',
    this.dailyScore = 0,
    this.dailyAccuracy = 0,
    this.newIntroYmd = '',
    this.newIntroCount = 0,
    this.placementRank = 0,
  });

  Map<String, dynamic> toJson() => {
        'streak': streak,
        'best': bestStreak,
        'last': lastPlayedYmd,
        'seen': lifetimeSeen,
        'correct': lifetimeCorrect,
        'dailyYmd': dailyYmd,
        'dailyScore': dailyScore,
        'dailyAcc': dailyAccuracy,
        'niYmd': newIntroYmd,
        'niCount': newIntroCount,
        if (placementRank > 0) 'plRank': placementRank,
      };

  factory PlayerProfile.fromJson(Map<String, dynamic> j) => PlayerProfile(
        streak: (j['streak'] as num?)?.toInt() ?? 0,
        bestStreak: (j['best'] as num?)?.toInt() ?? 0,
        lastPlayedYmd: (j['last'] as String?) ?? '',
        lifetimeSeen: (j['seen'] as num?)?.toInt() ?? 0,
        lifetimeCorrect: (j['correct'] as num?)?.toInt() ?? 0,
        dailyYmd: (j['dailyYmd'] as String?) ?? '',
        dailyScore: (j['dailyScore'] as num?)?.toInt() ?? 0,
        dailyAccuracy: (j['dailyAcc'] as num?)?.toInt() ?? 0,
        newIntroYmd: (j['niYmd'] as String?) ?? '',
        newIntroCount: (j['niCount'] as num?)?.toInt() ?? 0,
        placementRank: (j['plRank'] as num?)?.toInt() ?? 0,
      );
}
