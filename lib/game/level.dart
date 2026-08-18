import '../models/word.dart';

/// Matching word difficulty to the learner.
///
/// Two signals exist and they disagree about nothing, which is convenient:
/// every entry carries a `difficulty` (easy/medium/hard) and a `freqRank`, and
/// across the live catalogue the two line up closely —
///
///   freqRank      easy   medium   hard
///   0–3,000        92%      7%      0%
///   3,000–6,000    44%     51%      5%
///   6,000–10,000    4%     33%     63%
///   14,000+         0%     19%     80%
///
/// So the placement quiz's frequency rank can drive a difficulty band without
/// needing a second measurement. The catalogue as a whole skews hard (8,292
/// hard against 2,892 easy), which is why an unplaced learner previously met a
/// roughly 50/50 chance of a hard word on their very first round.
enum DifficultyPref {
  /// Derive the band from the placement rank. The default.
  auto,
  easy,
  medium,
  hard,
}

const Set<String> _easyMed = {'easy', 'medium'};
const Set<String> _all = {'easy', 'medium', 'hard'};
const Set<String> _medHard = {'medium', 'hard'};

/// Which difficulty bands to serve.
///
/// An explicit preference wins outright — if the learner asked for hard words,
/// they get hard words. Under [DifficultyPref.auto] the band comes from the
/// placement rank, and an *unplaced* learner (rank 0) is treated as a beginner
/// rather than given the run of the catalogue. That is the conservative
/// choice: being under-stretched is recoverable in a way that being drowned on
/// the first round is not.
Set<String> allowedDifficulties({
  required DifficultyPref pref,
  required int placementRank,
}) {
  switch (pref) {
    case DifficultyPref.easy:
      return const {'easy'};
    case DifficultyPref.medium:
      return const {'medium'};
    case DifficultyPref.hard:
      return const {'hard'};
    case DifficultyPref.auto:
      if (placementRank <= 0) return _easyMed; // not yet placed
      if (placementRank < 4000) return _easyMed;
      if (placementRank < 8000) return _all;
      return _medHard;
  }
}

/// Narrows [pool] to the bands from [allowedDifficulties].
///
/// Falls back to the unfiltered pool when the result would be too small to
/// deal a decent round — a custom set, a narrow track, or a learner whose
/// explicit preference happens to exclude nearly everything available. Serving
/// slightly-off-level words beats serving four.
List<Word> matchLevel(
  List<Word> pool, {
  required DifficultyPref pref,
  required int placementRank,
  int minPool = 40,
}) {
  final allowed = allowedDifficulties(pref: pref, placementRank: placementRank);
  if (allowed.length == _all.length) return pool;
  final filtered = pool.where((w) => allowed.contains(w.difficulty)).toList();
  return filtered.length >= minPool ? filtered : pool;
}

/// Whether the modes that ask the learner to PRODUCE the word — Spelling, and
/// Listen where the word is hidden — should be offered yet.
///
/// Gated on having been placed rather than on a rank threshold. The honest
/// reason is that without a placement we cannot match difficulty at all, so
/// those modes would be dealing words of unknown difficulty to a learner of
/// unknown ability. It also gives the placement quiz a reward for finishing it
/// instead of only a nag to start it.
bool producingModesUnlocked(int placementRank) => placementRank > 0;
