import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import '../data/progress_store.dart';
import '../models/word.dart';
import '../services/voice.dart';
import 'daily.dart';
import 'level.dart';
import 'spelling_match.dart';
import 'track.dart';

enum Phase { question, revealed, finished }

enum GameMode {
  quickPlay, // timed, drawn from the chosen track; word -> pick meaning
  review, // no timer, drawn from due + new words (spaced repetition)
  daily, // timed, deterministic 10-word set for today
  reverse, // timed; definition shown -> pick the WORD
  listen, // timed; word spoken (hidden) -> pick the meaning
  spelling, // timed; word spoken (hidden) -> type the WORD (dictation)
}

/// Holds all state for one match and records results into the ProgressStore.
class GameController extends ChangeNotifier {
  GameController(
    this._all, {
    required this.store,
    required this.locale,
    this.mode = GameMode.quickPlay,
    this.recordProgress = true,
    this.difficultyPref = DifficultyPref.auto,
  });

  final List<Word> _all;
  final ProgressStore store;
  final String locale;
  final GameMode mode;

  /// When false (custom sets), answers don't feed the SRS / streak / stats.
  final bool recordProgress;

  /// Learner's difficulty setting; [DifficultyPref.auto] derives it from the
  /// placement rank.
  final DifficultyPref difficultyPref;

  List<Word>? _levelPoolCache;

  /// [_all] narrowed to the learner's level. Everything that deals words draws
  /// from here rather than the raw catalogue, so the level applies to reviews,
  /// the daily set, the track pools and the reverse-mode distractors alike.
  ///
  /// Custom sets opt out: the learner chose those words deliberately, and it
  /// would be rude to hide half of them.
  List<Word> get _levelPool => _levelPoolCache ??= recordProgress
      ? matchLevel(_all,
          pref: difficultyPref, placementRank: store.placementRank)
      : _all;

  Gloss get _g => current.glossFor(locale);

  bool get isReverse => mode == GameMode.reverse;
  bool get isListen => mode == GameMode.listen;
  bool get isSpelling => mode == GameMode.spelling;

  /// The answer that counts as correct this round (the word itself in
  /// reverse/spelling modes, a meaning otherwise).
  String get correctAnswer =>
      (isReverse || isSpelling) ? current.word : _g.correct;

  /// Case/whitespace-insensitive match — spelling mode shouldn't fail someone
  /// over a stray capital letter or trailing space from the keyboard.
  // Spelling answers fold away diacritics — see normalizeSpelling().
  String _normalize(String s) => normalizeSpelling(s);

  /// Reverse mode: three WORDS to choose from (correct + 2 same-difficulty).
  List<String> _reverseOptions() {
    final same = _levelPool
        .where((w) => w.id != current.id && w.difficulty == current.difficulty)
        .toList()
      ..shuffle();
    final pool = same.length >= 2
        ? same
        : (_all.where((w) => w.id != current.id).toList()..shuffle());
    // Dedupe by surface form so no option repeats the correct word or itself.
    final seen = <String>{current.word};
    final distractors = <String>[];
    for (final w in pool) {
      if (distractors.length >= 2) break;
      if (seen.add(w.word)) distractors.add(w.word);
    }
    if (distractors.length < 2) {
      for (final w in _all) {
        if (distractors.length >= 2) break;
        if (seen.add(w.word)) distractors.add(w.word);
      }
    }
    final opts = <String>[current.word, ...distractors]..shuffle();
    return opts;
  }

  static const int roundsPerMatch = 10;
  static const int totalMs = 8000;
  static const int _tickMs = 16;

  bool get timed => mode != GameMode.review;

  final List<Word> _deck = [];
  int index = 0;
  int score = 0;
  int streak = 0;
  int bestStreak = 0;
  int correctCount = 0;

  Phase phase = Phase.question;
  List<String> currentOptions = const [];
  String? chosen;
  bool wasCorrect = false;
  double remainingMs = totalMs.toDouble();
  bool timedOut = false;

  Timer? _timer;

  /// Fired once, right when the round transitions to [Phase.finished] —
  /// GameScreen uses this to clear any saved mid-round snapshot.
  VoidCallback? onFinished;

  Word get current => _deck[index];
  int get total => _deck.length;
  bool get isLast => index == _deck.length - 1;
  double get progress => (remainingMs / totalMs).clamp(0.0, 1.0);
  int get accuracy =>
      _deck.isEmpty ? 0 : ((correctCount / _deck.length) * 100).round();

  /// Persisted, growing rank from the store (falls back to a session estimate).
  int get vocabRank => store.vocabRank();

  void start(Track track) {
    final List<Word> pool;
    if (mode == GameMode.review) {
      pool = _reviewDeck();
    } else if (mode == GameMode.daily) {
      pool = dailyDeck(_levelPool, DateTime.now(), count: roundsPerMatch);
    } else {
      pool = _levelPool
          .where(track.filter)
          .where((w) => !store.progressFor(w.id).suspended)
          .toList()
        ..shuffle();
    }
    _deck
      ..clear()
      ..addAll(pool.take(roundsPerMatch));
    index = 0;
    score = 0;
    streak = 0;
    bestStreak = 0;
    correctCount = 0;
    _prefetchDeck();
    _beginQuestion();
  }

  /// True once a round has been dealt and isn't finished yet — used to decide
  /// whether exiting mid-round has anything worth saving.
  bool get inProgress =>
      _deck.isNotEmpty && phase != Phase.finished && index < _deck.length;

  /// Serialize enough state to resume this exact round later (mid-round exit).
  Map<String, dynamic> snapshot() => {
        'deckIds': _deck.map((w) => w.id).toList(),
        'index': index,
        'score': score,
        'streak': streak,
        'bestStreak': bestStreak,
        'correctCount': correctCount,
        'savedAtMillis': DateTime.now().millisecondsSinceEpoch,
      };

  /// Resume a previously-saved round instead of dealing a fresh deck. Throws
  /// [StateError] if none of the saved words are available any more (e.g. the
  /// library changed) — the caller should fall back to [start] in that case.
  void resume(Map<String, dynamic> snap) {
    final ids = (snap['deckIds'] as List).cast<String>();
    final byId = {for (final w in _all) w.id: w};
    final restored = ids.map((id) => byId[id]).whereType<Word>().toList();
    if (restored.isEmpty) throw StateError('snapshot words unavailable');
    _deck
      ..clear()
      ..addAll(restored);
    index = ((snap['index'] as num?)?.toInt() ?? 0).clamp(0, _deck.length - 1);
    score = (snap['score'] as num?)?.toInt() ?? 0;
    streak = (snap['streak'] as num?)?.toInt() ?? 0;
    bestStreak = (snap['bestStreak'] as num?)?.toInt() ?? 0;
    correctCount = (snap['correctCount'] as num?)?.toInt() ?? 0;
    _prefetchDeck();
    _beginQuestion();
  }

  /// Fire-and-forget cache warm-up for the whole deck, so ElevenLabs audio
  /// for upcoming words (and their definitions) is already cached on-device
  /// by the time each question needs it. Voice.speak() only waits ~2.5s for
  /// a fresh network fetch before degrading to the instant on-device voice —
  /// this is what makes that timeout rarely get hit at all instead of the
  /// auto-read feeling like it "didn't happen". Batched with limited
  /// concurrency so it doesn't starve the current question's live request.
  void _prefetchDeck() {
    final words = List<Word>.from(_deck);
    () async {
      const batchSize = 3;
      for (var i = 0; i < words.length; i += batchSize) {
        final batch = words.skip(i).take(batchSize);
        await Future.wait(batch.map((w) async {
          await Voice.instance.prefetch(w.word,
              langCode: w.lang,
              headword: w.word,
              headwordPos: w.pos,
              sayAs: w.say);
          await Voice.instance.prefetch(w.glossFor(locale).correct,
              langCode: locale,
              headword: w.word,
              headwordPos: w.pos,
              sayAs: w.say);
        }));
      }
    }();
  }

  /// Due words first (spaced repetition), then a capped number of NEW words
  /// (the daily new-word budget — the forgiving catch-up guard), then
  /// not-yet-due words to fill the match. Known/suspended words are skipped.
  List<Word> _reviewDeck() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final due = <Word>[];
    final unseen = <Word>[];
    final future = <Word>[];
    for (final w in _levelPool) {
      final wp = store.progressFor(w.id);
      if (wp.suspended) continue;
      if (wp.seen == 0) {
        unseen.add(w);
      } else if (wp.dueAtMillis <= now) {
        due.add(w);
      } else {
        future.add(w);
      }
    }
    due.shuffle();
    future.shuffle();
    // If the learner has been placed, introduce NEW words near their level
    // (at or just above it) instead of at random.
    if (store.placed) {
      final r = store.placementRank;
      int dist(Word w) =>
          w.freqRank < r ? (r - w.freqRank) * 2 : (w.freqRank - r);
      unseen.sort((a, b) => dist(a).compareTo(dist(b)));
    } else {
      unseen.shuffle();
    }
    final cappedUnseen = unseen.take(store.newRemainingToday()).toList();
    return [...due, ...cappedUnseen, ...future];
  }

  /// Mark the current word "known" so it stops appearing (learner control).
  void markCurrentKnown() {
    if (recordProgress) store.markKnown(current.id); // not for custom sets
    notifyListeners();
  }

  bool get currentKnown => store.progressFor(current.id).suspended;

  /// Report the current question as having a content problem.
  void flagCurrent() {
    if (recordProgress) store.flagWord(current.id); // not for custom sets
    notifyListeners();
  }

  bool get currentFlagged => store.isFlagged(current.id);

  void _beginQuestion() {
    phase = Phase.question;
    chosen = null;
    wasCorrect = false;
    timedOut = false;
    currentOptions =
        isReverse ? _reverseOptions() : (isSpelling ? const [] : _g.shuffledOptions());
    remainingMs = totalMs.toDouble();
    if (!isReverse) {
      Voice.instance.speak(current.word,
          langCode: current.lang,
          headword: current.word,
          headwordPos: current.pos,
          sayAs: current.say);
    }
    _timer?.cancel();
    if (timed) {
      _timer = Timer.periodic(const Duration(milliseconds: _tickMs), (_) {
        remainingMs -= _tickMs;
        if (remainingMs <= 0) {
          remainingMs = 0;
          _onTimeout();
        }
        notifyListeners();
      });
    }
    notifyListeners();
  }

  void choose(String option) {
    if (phase != Phase.question) return;
    _timer?.cancel();
    chosen = option;
    wasCorrect = isSpelling
        ? _normalize(option) == _normalize(correctAnswer)
        : option == correctAnswer;
    if (wasCorrect) {
      correctCount++;
      streak++;
      if (streak > bestStreak) bestStreak = streak;
      final speedBonus =
          timed ? ((remainingMs / totalMs) * 50).round() : 30;
      final diffBonus = _difficultyBonus(current.difficulty);
      score += diffBonus + speedBonus + streak * 5;
      HapticFeedback.lightImpact();
    } else {
      streak = 0;
      HapticFeedback.mediumImpact();
    }
    _record(wasCorrect);
    _speakReveal();
    phase = Phase.revealed;
    notifyListeners();
  }

  void _speakReveal() {
    // Reverse + Listen + Spelling reinforce the target word; classic reads the meaning.
    if (isReverse || isListen || isSpelling) {
      Voice.instance.speak(current.word,
          langCode: current.lang,
          headword: current.word,
          headwordPos: current.pos,
          sayAs: current.say);
    } else {
      Voice.instance.speak(_g.correct,
          langCode: locale,
          headword: current.word,
          headwordPos: current.pos,
          sayAs: current.say);
    }
  }

  void _onTimeout() {
    _timer?.cancel();
    streak = 0;
    chosen = null;
    wasCorrect = false;
    timedOut = true;
    _record(false);
    _speakReveal();
    phase = Phase.revealed;
    notifyListeners();
  }

  void _record(bool correct) {
    if (!recordProgress) return; // custom sets don't touch the SRS
    // Fire-and-forget; the store persists asynchronously.
    store.recordAnswer(
      current.id,
      correct,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  void next() {
    if (isLast) {
      _timer?.cancel();
      phase = Phase.finished;
      if (recordProgress) {
        _registerStreak();
        if (mode == GameMode.daily) {
          store.recordDaily(_ymd(DateTime.now()), score, accuracy);
        }
      }
      onFinished?.call();
      notifyListeners();
    } else {
      index++;
      _beginQuestion();
    }
  }

  void _registerStreak() {
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    store.registerPlay(_ymd(now), _ymd(yesterday));
  }

  String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  int _difficultyBonus(String d) {
    switch (d) {
      case 'hard':
        return 120;
      case 'medium':
        return 80;
      default:
        return 50;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
