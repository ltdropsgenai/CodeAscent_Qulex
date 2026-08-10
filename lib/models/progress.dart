/// Per-word learning state (Leitner spaced repetition) + the player profile.
/// Persisted as JSON via ProgressStore.

class WordProgress {
  int box; // Leitner box 0..maxBox; higher = better known, longer interval
  int seen;
  int correct;
  int dueAtMillis; // epoch ms when this word is next due for review
  bool suspended; // user marked "known — stop showing"; excluded from decks

  WordProgress({
    this.box = 0,
    this.seen = 0,
    this.correct = 0,
    this.dueAtMillis = 0,
    this.suspended = false,
  });

  Map<String, dynamic> toJson() => {
        'box': box,
        'seen': seen,
        'correct': correct,
        'due': dueAtMillis,
        if (suspended) 'susp': true,
      };

  factory WordProgress.fromJson(Map<String, dynamic> j) => WordProgress(
        box: (j['box'] as num?)?.toInt() ?? 0,
        seen: (j['seen'] as num?)?.toInt() ?? 0,
        correct: (j['correct'] as num?)?.toInt() ?? 0,
        dueAtMillis: (j['due'] as num?)?.toInt() ?? 0,
        suspended: (j['susp'] as bool?) ?? false,
      );
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
