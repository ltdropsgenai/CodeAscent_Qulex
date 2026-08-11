import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../game/srs.dart';
import '../models/progress.dart';

/// Persists learning progress locally (shared_preferences works on web +
/// mobile + desktop). Swap for a Supabase-backed store later without touching
/// the game code — the controller only calls the methods below.
class ProgressStore {
  static const _kWords = 'qbit_word_progress_v1';
  static const _kProfile = 'qbit_profile_v1';
  static const _kFlagged = 'qbit_flagged_v1';
  static const _kRoundSnapshots = 'qbit_round_snapshots_v1';

  final Map<String, WordProgress> _words = {};
  final Set<String> _flagged = {};
  final Map<String, Map<String, dynamic>> _roundSnapshots = {};
  PlayerProfile profile = PlayerProfile();

  /// Learner-tunable spaced-repetition settings (driven by app settings).
  int newPerDay = 20; // cap on brand-new words introduced per day
  double intervalScale = 1.0; // <1 = more frequent reviews, >1 = more relaxed

  String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final rawWords = p.getString(_kWords);
    if (rawWords != null) {
      final m = json.decode(rawWords) as Map<String, dynamic>;
      _words.clear();
      m.forEach((k, v) =>
          _words[k] = WordProgress.fromJson(v as Map<String, dynamic>));
    }
    final rawProfile = p.getString(_kProfile);
    if (rawProfile != null) {
      profile =
          PlayerProfile.fromJson(json.decode(rawProfile) as Map<String, dynamic>);
    }
    _flagged
      ..clear()
      ..addAll(p.getStringList(_kFlagged) ?? const []);
    final rawSnapshots = p.getString(_kRoundSnapshots);
    _roundSnapshots.clear();
    if (rawSnapshots != null) {
      final m = json.decode(rawSnapshots) as Map<String, dynamic>;
      m.forEach((k, v) => _roundSnapshots[k] = (v as Map).cast<String, dynamic>());
    }
  }

  // --- Mid-round exit / resume ---------------------------------------------
  // A round in progress (deck + position + score) is keyed by "trackId|mode"
  // so returning to the same track+mode can offer Resume vs Start New instead
  // of silently discarding an unfinished round.

  String _roundKey(String trackId, String mode) => '$trackId|$mode';

  /// Save (or overwrite) the in-progress round for [trackId]/[mode].
  Future<void> saveRoundSnapshot(
      String trackId, String mode, Map<String, dynamic> data) async {
    _roundSnapshots[_roundKey(trackId, mode)] = data;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kRoundSnapshots, json.encode(_roundSnapshots));
  }

  /// The saved in-progress round for [trackId]/[mode], if any.
  Map<String, dynamic>? roundSnapshot(String trackId, String mode) =>
      _roundSnapshots[_roundKey(trackId, mode)];

  /// Clear the saved round for [trackId]/[mode] (round finished or discarded).
  Future<void> clearRoundSnapshot(String trackId, String mode) async {
    if (_roundSnapshots.remove(_roundKey(trackId, mode)) == null) return;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kRoundSnapshots, json.encode(_roundSnapshots));
  }

  /// Flag a word/question as having a content problem (user report).
  Future<void> flagWord(String wordId) async {
    if (!_flagged.add(wordId)) return;
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_kFlagged, _flagged.toList());
  }

  bool isFlagged(String wordId) => _flagged.contains(wordId);

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    final m = {for (final e in _words.entries) e.key: e.value.toJson()};
    await p.setString(_kWords, json.encode(m));
    await p.setString(_kProfile, json.encode(profile.toJson()));
  }

  WordProgress progressFor(String wordId) =>
      _words[wordId] ?? WordProgress();

  /// Record one answer and reschedule the word via the Leitner system.
  Future<void> recordAnswer(String wordId, bool correct, int nowMillis) async {
    final wp = _words.putIfAbsent(wordId, WordProgress.new);
    final wasUnseen = wp.seen == 0;
    wp.seen += 1;
    if (correct) wp.correct += 1;
    wp.box = Srs.nextBox(wp.box, correct);
    wp.dueAtMillis = Srs.dueFrom(nowMillis, wp.box, scale: intervalScale);
    profile.lifetimeSeen += 1;
    if (correct) profile.lifetimeCorrect += 1;
    if (wasUnseen) _bumpNewIntro(nowMillis);
    await _save();
  }

  void _bumpNewIntro(int nowMillis) {
    final today = _ymd(DateTime.fromMillisecondsSinceEpoch(nowMillis));
    if (profile.newIntroYmd != today) {
      profile.newIntroYmd = today;
      profile.newIntroCount = 0;
    }
    profile.newIntroCount += 1;
  }

  /// New (unseen) words still allowed to be introduced today under [newPerDay].
  int newRemainingToday() {
    final today = _ymd(DateTime.now());
    final used = profile.newIntroYmd == today ? profile.newIntroCount : 0;
    final rem = newPerDay - used;
    return rem < 0 ? 0 : rem;
  }

  /// Mark a word "known" so it stops appearing in decks.
  Future<void> markKnown(String wordId) async {
    final wp = _words.putIfAbsent(wordId, WordProgress.new);
    wp.suspended = true;
    wp.box = Srs.maxBox;
    if (wp.seen == 0) wp.seen = 1; // counts toward "known"
    await _save();
  }

  /// Bring all "known/suspended" words back into rotation (due now, box eased).
  Future<int> resurfaceMastered() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    var n = 0;
    for (final wp in _words.values) {
      if (wp.suspended) {
        wp.suspended = false;
        wp.box = wp.box > 2 ? 2 : wp.box;
        wp.dueAtMillis = now;
        n++;
      }
    }
    if (n > 0) await _save();
    return n;
  }

  int knownSuspendedCount() =>
      _words.values.where((w) => w.suspended).length;

  // --- Adaptive placement ---
  int get placementRank => profile.placementRank;
  bool get placed => profile.placementRank > 0;
  Future<void> savePlacement(int rank) async {
    profile.placementRank = rank;
    await _save();
  }

  /// Update the daily streak. Call once when a match completes.
  Future<void> registerPlay(String todayYmd, String yesterdayYmd) async {
    if (profile.lastPlayedYmd == todayYmd) return; // already counted today
    if (profile.lastPlayedYmd == yesterdayYmd) {
      profile.streak += 1;
    } else {
      profile.streak = 1;
    }
    if (profile.streak > profile.bestStreak) {
      profile.bestStreak = profile.streak;
    }
    profile.lastPlayedYmd = todayYmd;
    await _save();
  }

  /// Record a completed Daily Challenge.
  Future<void> recordDaily(String todayYmd, int score, int accuracy) async {
    profile.dailyYmd = todayYmd;
    profile.dailyScore = score;
    profile.dailyAccuracy = accuracy;
    await _save();
  }

  bool dailyDoneToday(String todayYmd) => profile.dailyYmd == todayYmd;

  /// Words considered "known" (reached box 2+).
  int knownCount() => _words.values.where((w) => w.box >= 2).length;

  /// Words that have been seen and are now due for review (excludes known ones).
  int dueCount(int nowMillis) => _words.values
      .where((w) => !w.suspended && w.seen > 0 && w.dueAtMillis <= nowMillis)
      .length;

  /// Prototype Vocab Rank: a base plus a bump per word you actually know.
  int vocabRank() => 800 + knownCount() * 60;

  // ---------------------------------------------------------------------------
  // Cloud sync (used by SyncService). The store stays the single source of
  // truth locally; these methods let the sync layer read/merge a remote copy.
  // ---------------------------------------------------------------------------

  int get wordCount => _words.length;

  /// A full serializable snapshot of learning state for upload.
  Map<String, dynamic> exportState() => {
        'words': {for (final e in _words.entries) e.key: e.value.toJson()},
        'profile': profile.toJson(),
      };

  /// Bring a remote snapshot into the local store, then persist.
  /// When [merge] is true, per-word and profile fields are combined so no
  /// progress is lost across devices; when false, remote replaces local.
  Future<void> importState(Map<String, dynamic> remote,
      {bool merge = true}) async {
    final rWords = (remote['words'] as Map?)?.cast<String, dynamic>() ?? const {};
    final rProfile = (remote['profile'] as Map?)?.cast<String, dynamic>();

    if (!merge) _words.clear();
    rWords.forEach((k, v) {
      final incoming =
          WordProgress.fromJson((v as Map).cast<String, dynamic>());
      final existing = _words[k];
      _words[k] = (existing == null || !merge)
          ? incoming
          : _mergeWord(existing, incoming);
    });

    if (rProfile != null) {
      final rp = PlayerProfile.fromJson(rProfile);
      profile = merge ? _mergeProfile(profile, rp) : rp;
    }
    await _save();
  }

  WordProgress _mergeWord(WordProgress a, WordProgress b) {
    // The record with more exposure wins the schedule; box never regresses.
    final win = b.seen > a.seen ? b : a;
    final other = identical(win, a) ? b : a;
    return WordProgress(
      box: win.box > other.box ? win.box : other.box,
      seen: win.seen,
      correct: win.correct > other.correct ? win.correct : other.correct,
      dueAtMillis: win.dueAtMillis,
      // "Known" on either device wins, so a suspension is never lost on sync.
      suspended: win.suspended || other.suspended,
    );
  }

  PlayerProfile _mergeProfile(PlayerProfile a, PlayerProfile b) {
    int mx(int x, int y) => x > y ? x : y;
    // Day/string fields follow whichever profile played most recently; the
    // cumulative counters take the max (avoids double-counting shared plays).
    final base = a.lastPlayedYmd.compareTo(b.lastPlayedYmd) >= 0 ? a : b;
    return PlayerProfile(
      streak: mx(a.streak, b.streak),
      bestStreak: mx(a.bestStreak, b.bestStreak),
      lastPlayedYmd: base.lastPlayedYmd,
      lifetimeSeen: mx(a.lifetimeSeen, b.lifetimeSeen),
      lifetimeCorrect: mx(a.lifetimeCorrect, b.lifetimeCorrect),
      dailyYmd: base.dailyYmd,
      dailyScore: base.dailyScore,
      dailyAccuracy: base.dailyAccuracy,
      // Keep the new-word counter tied to the most-recent day so the daily cap
      // isn't reset by a sync.
      newIntroYmd: base.newIntroYmd,
      newIntroCount: base.newIntroCount,
      // Placement is a "current level", not a lifetime max — the most recently
      // played profile's value wins so a re-take isn't overridden.
      placementRank: base.placementRank > 0 ? base.placementRank : mx(a.placementRank, b.placementRank),
    );
  }
}
