import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../game/daily.dart' show ymd;
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

  /// Sections that could not be read on the last [load], in plain language.
  ///
  /// Empty is the normal case. Non-empty means we started that section from
  /// scratch rather than refusing to start at all — the UI should say so once,
  /// because silently resetting someone's streak is worse than telling them.
  final List<String> loadWarnings = [];

  String _ymd(DateTime d) => ymd(d);

  // ---------------------------------------------------------------------------
  // Load
  //
  // Every section is parsed independently and every one can fail without taking
  // the others — or the app — with it. This used to be four unguarded
  // json.decode + cast expressions in a row, so a single truncated write (a
  // process killed mid-setString, a device out of space) threw out of load(),
  // out of HomeScreen's _load(), and into the FutureBuilder's error branch,
  // where the only offer was "Failed to load: FormatException". There was no
  // way back except reinstalling, which deletes the very progress the screen
  // was failing to read.
  //
  // A damaged value is moved aside rather than discarded, so it can still be
  // recovered from a support request instead of being gone for good.
  // ---------------------------------------------------------------------------

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    loadWarnings.clear();

    await _section(p, _kWords, 'word progress', () {
      final raw = p.getString(_kWords);
      if (raw == null) return;
      final m = json.decode(raw) as Map<String, dynamic>;
      final parsed = <String, WordProgress>{};
      var skipped = 0;
      m.forEach((k, v) {
        // One bad entry costs one word, not the whole history.
        try {
          parsed[k] = WordProgress.fromJson((v as Map).cast<String, dynamic>());
        } catch (_) {
          skipped++;
        }
      });
      _words
        ..clear()
        ..addAll(parsed);
      if (skipped > 0) {
        loadWarnings.add('$skipped word${skipped == 1 ? '' : 's'} had damaged '
            'progress and were reset.');
      }
    });

    await _section(p, _kProfile, 'your profile and streak', () {
      final raw = p.getString(_kProfile);
      if (raw == null) return;
      profile =
          PlayerProfile.fromJson(json.decode(raw) as Map<String, dynamic>);
    });

    await _section(p, _kFlagged, 'reported words', () {
      _flagged
        ..clear()
        ..addAll(p.getStringList(_kFlagged) ?? const []);
    });

    await _section(p, _kRoundSnapshots, 'unfinished rounds', () {
      _roundSnapshots.clear();
      final raw = p.getString(_kRoundSnapshots);
      if (raw == null) return;
      final m = json.decode(raw) as Map<String, dynamic>;
      m.forEach((k, v) {
        try {
          _roundSnapshots[k] = (v as Map).cast<String, dynamic>();
        } catch (_) {/* one unusable snapshot, not all of them */}
      });
    });

    // Drop rounds nobody is coming back to (see _snapshotTtl).
    _pruneSnapshots();
  }

  /// Runs one section of [load], containing any failure to that section.
  Future<void> _section(SharedPreferences p, String key, String label,
      void Function() body) async {
    try {
      body();
    } catch (e) {
      loadWarnings.add('Could not read $label — starting that part fresh.');
      await _quarantine(p, key);
    }
  }

  /// Moves an unreadable value out of the way so the next launch is clean,
  /// keeping one copy for diagnosis. A single slot, overwritten, so repeated
  /// failures can't grow storage without bound.
  Future<void> _quarantine(SharedPreferences p, String key) async {
    try {
      final raw = p.getString(key);
      if (raw != null) {
        await p.setString('${key}__corrupt', raw);
      } else {
        final list = p.getStringList(key);
        if (list != null) await p.setStringList('${key}__corrupt', list);
      }
      await p.remove(key);
    } catch (_) {
      // If we can't even quarantine it, removing it is still worth trying.
      try {
        await p.remove(key);
      } catch (_) {}
    }
  }

  // --- Mid-round exit / resume ---------------------------------------------
  // A round in progress (deck + position + score) is keyed by "trackId|mode"
  // so returning to the same track+mode can offer Resume vs Start New instead
  // of silently discarding an unfinished round.

  /// How long an unfinished round stays on offer. `savedAtMillis` was always
  /// recorded and never read, so a round abandoned months ago was still met
  /// with "Resume — question 4 of 10", about words the learner has since
  /// forgotten they were mid-way through.
  static const _snapshotTtl = Duration(days: 30);

  String _roundKey(String trackId, String mode) => '$trackId|$mode';

  bool _isFresh(Map<String, dynamic> snap) {
    final saved = (snap['savedAtMillis'] as num?)?.toInt();
    if (saved == null) return true; // pre-dates the field; give it the benefit
    return DateTime.now().millisecondsSinceEpoch - saved <=
        _snapshotTtl.inMilliseconds;
  }

  void _pruneSnapshots() =>
      _roundSnapshots.removeWhere((_, snap) => !_isFresh(snap));

  /// Save (or overwrite) the in-progress round for [trackId]/[mode].
  Future<void> saveRoundSnapshot(
      String trackId, String mode, Map<String, dynamic> data) async {
    _roundSnapshots[_roundKey(trackId, mode)] = data;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kRoundSnapshots, json.encode(_roundSnapshots));
  }

  /// The saved in-progress round for [trackId]/[mode], if any and still fresh.
  Map<String, dynamic>? roundSnapshot(String trackId, String mode) {
    final snap = _roundSnapshots[_roundKey(trackId, mode)];
    if (snap == null) return null;
    if (!_isFresh(snap)) {
      _roundSnapshots.remove(_roundKey(trackId, mode));
      return null;
    }
    return snap;
  }

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

  // ---------------------------------------------------------------------------
  // Save
  //
  // Writes are coalesced. This used to re-encode the ENTIRE word map on every
  // single answer: measured at 5.7ms and 229KB with 4,000 words known, which
  // extrapolates to roughly 20ms and ~900KB per answer across the full 16,808
  // catalogue — on the UI isolate, in a game built around an 8-second timer,
  // and a lot of flash churn for one integer changing.
  //
  // In-memory state is still updated synchronously, so nothing downstream can
  // read a stale value; only the trip to disk is deferred. [flush] forces it,
  // and callers who are about to lose the process (app backgrounded, round
  // finished, cloud push) call it.
  // ---------------------------------------------------------------------------

  static const _saveDebounce = Duration(milliseconds: 700);
  Timer? _saveTimer;
  Future<void>? _saveInFlight;
  bool _dirty = false;

  void _scheduleSave() {
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, () {
      _saveTimer = null;
      flush();
    });
  }

  /// Write pending changes now. Safe to call at any time, including when
  /// nothing is pending. Never throws — a failed write leaves [_dirty] set so
  /// the next attempt retries rather than silently dropping the change.
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_dirty) return _saveInFlight ?? Future<void>.value();
    // Serialize concurrent flushes so two encodes can't interleave writes.
    final pending = _saveInFlight;
    if (pending != null) {
      await pending;
      if (!_dirty) return;
    }
    final job = _writeNow();
    _saveInFlight = job;
    try {
      await job;
    } finally {
      if (identical(_saveInFlight, job)) _saveInFlight = null;
    }
  }

  Future<void> _writeNow() async {
    _dirty = false;
    try {
      final p = await SharedPreferences.getInstance();
      final m = {for (final e in _words.entries) e.key: e.value.toJson()};
      await p.setString(_kWords, json.encode(m));
      await p.setString(_kProfile, json.encode(profile.toJson()));
    } catch (_) {
      _dirty = true; // keep it pending; the next flush retries
    }
  }

  WordProgress progressFor(String wordId) => _words[wordId] ?? WordProgress();

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
    _scheduleSave();
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
    _scheduleSave();
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
    if (n > 0) await flush(); // a deliberate bulk action; don't defer it
    return n;
  }

  int knownSuspendedCount() => _words.values.where((w) => w.suspended).length;

  /// True when there is nothing left to review — every word the learner has
  /// met is suspended and none are due. Lets callers say something useful
  /// instead of dealing an empty round.
  bool get allSuspended =>
      _words.isNotEmpty && _words.values.every((w) => w.suspended);

  // --- Adaptive placement ---
  int get placementRank => profile.placementRank;
  bool get placed => profile.placementRank > 0;
  Future<void> savePlacement(int rank) async {
    profile.placementRank = rank;
    await flush(); // one-off and consequential; write it through
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
    await flush(); // end of a round — the process may not be around much longer
  }

  /// Record a completed Daily Challenge.
  Future<void> recordDaily(String todayYmd, int score, int accuracy) async {
    profile.dailyYmd = todayYmd;
    profile.dailyScore = score;
    profile.dailyAccuracy = accuracy;
    await flush();
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
    final rWords =
        (remote['words'] as Map?)?.cast<String, dynamic>() ?? const {};
    final rProfile = (remote['profile'] as Map?)?.cast<String, dynamic>();

    if (!merge) _words.clear();
    rWords.forEach((k, v) {
      // A remote row is data we did not write and cannot vouch for; one bad
      // entry must not abort the whole sync.
      try {
        final incoming =
            WordProgress.fromJson((v as Map).cast<String, dynamic>());
        final existing = _words[k];
        _words[k] = (existing == null || !merge)
            ? incoming
            : _mergeWord(existing, incoming);
      } catch (_) {/* skip this word */}
    });

    if (rProfile != null) {
      try {
        final rp = PlayerProfile.fromJson(rProfile);
        profile = merge ? _mergeProfile(profile, rp) : rp;
      } catch (_) {/* keep the local profile */}
    }
    await flush();
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
      placementRank: base.placementRank > 0
          ? base.placementRank
          : mx(a.placementRank, b.placementRank),
    );
  }

  /// Stop the debounce timer. Call from dispose paths; pending changes are
  /// written first so nothing is lost.
  Future<void> dispose() async {
    await flush();
    _saveTimer?.cancel();
    _saveTimer = null;
  }
}
