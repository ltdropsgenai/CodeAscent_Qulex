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
  bool timedOut = false;

  /// The countdown, on its own channel.
  ///
  /// This used to be a plain field updated inside a 16ms Timer that called
  /// notifyListeners() on every tick — so the entire question screen rebuilt
  /// sixty times a second, for the full eight seconds of every timed question,
  /// on top of the background's Ken Burns animation. Only the progress bar
  /// actually changes. Listening to this notifier instead of the controller
  /// keeps the rebuild to the two-pixel bar that needs it.
  final ValueNotifier<double> remaining =
      ValueNotifier<double>(totalMs.toDouble());

  double get remainingMs => remaining.value;
  set remainingMs(double v) => remaining.value = v;

  /// True when the deck came back empty and no round could be dealt. The
  /// screen shows an explanation instead of a scoreboard for zero questions.
  bool dealtEmpty = false;

  Timer? _timer;
  int _prefetchGeneration = 0;

  /// Fired once, right when the round transitions to [Phase.finished] —
  /// GameScreen uses this to clear any saved mid-round snapshot.
  VoidCallback? onFinished;

  Word get current => _deck[index];

  /// The id of the nth dealt word. Exposed so tests can compare two dealt
  /// decks without reaching into private state.
  String deckIdAt(int i) => _deck[i].id;
  int get total => _deck.length;
  bool get isLast => index == _deck.length - 1;
  double get progress => (remainingMs / totalMs).clamp(0.0, 1.0);
  int get accuracy =>
      _deck.isEmpty ? 0 : ((correctCount / _deck.length) * 100).round();

  /// Persisted, growing rank from the store (falls back to a session estimate).
  int get vocabRank => store.vocabRank();

  void start(Track track) {
    final pool = _deal(track);

    _deck
      ..clear()
      ..addAll(pool.take(roundsPerMatch));
    index = 0;
    score = 0;
    streak = 0;
    bestStreak = 0;
    correctCount = 0;
    timedOut = false;
    chosen = null;

    // A round with no words is a real outcome, not an impossible one — see
    // [_deal]. It has to be handled here, because _beginQuestion() reads
    // `current`, and `current` on an empty deck is a RangeError thrown out of
    // GameScreen.initState(), which leaves the learner staring at the generic
    // error panel on a route they can only back out of.
    dealtEmpty = _deck.isEmpty;
    if (dealtEmpty) {
      _timer?.cancel();
      phase = Phase.finished;
      notifyListeners();
      return;
    }

    phase = Phase.question;
    _prefetchDeck();
    _beginQuestion();
  }

  /// Deals the pool for [track], widening rather than coming back empty.
  ///
  /// Two paths could legitimately produce nothing, and both were reachable:
  ///
  ///  * A track whose tag doesn't intersect the learner's difficulty band.
  ///    Setting difficulty to Easy and opening the GRE track is the clean
  ///    example — of 367 GRE-tagged words in the catalogue, 240 are hard and
  ///    127 medium, and not one is easy. `matchLevel` doesn't rescue it either,
  ///    because 2,892 easy words is far above its minimum, so there is nothing
  ///    to trigger a fallback.
  ///  * Review mode once every word the learner has met is marked known.
  ///
  /// So we step outwards: the track at the learner's level, then the track
  /// across the whole catalogue, then anything at all. Serving a slightly
  /// off-level word beats serving a dead screen. Only if the catalogue itself
  /// is empty do we give up, and then we say so.
  List<Word> _deal(Track track) {
    if (mode == GameMode.review) {
      final due = _reviewDeck();
      if (due.isNotEmpty) return due;
      // Nothing due and nothing new — fall back to a plain round over
      // whatever isn't suspended, then to everything.
      final unsuspended = _levelPool
          .where((w) => !store.progressFor(w.id).suspended)
          .toList()
        ..shuffle();
      if (unsuspended.isNotEmpty) return unsuspended;
      return List<Word>.from(_all)..shuffle();
    }

    if (mode == GameMode.daily) {
      // Drawn from the WHOLE catalogue, deliberately: the Daily Challenge is
      // the one thing here that is meant to be the same for everybody on a
      // given day. Passing the level-filtered pool made it neither shared nor
      // stable — finishing a placement mid-day changed today's deck.
      final deck = dailyDeck(_all, DateTime.now(), count: roundsPerMatch);
      if (deck.isNotEmpty) return deck;
      return List<Word>.from(_all)..shuffle();
    }

    bool playable(Word w) => !store.progressFor(w.id).suspended;

    // poolForTrack tops up thin tag-backed tracks (IELTS matches only 41
    // words) with comparable ones, so a track normally has a round in it.
    final atLevel = poolForTrack(track, _levelPool).where(playable).toList()
      ..shuffle();
    if (atLevel.isNotEmpty) return atLevel;

    final anyLevel = poolForTrack(track, _all).where(playable).toList()
      ..shuffle();
    if (anyLevel.isNotEmpty) return anyLevel;

    final anything = _all.where(playable).toList()..shuffle();
    if (anything.isNotEmpty) return anything;

    // Everything is suspended. Rather than a dead end, let the screen offer
    // "bring my mastered words back" — see ProgressStore.allSuspended.
    return const [];
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
    dealtEmpty = false;
    phase = Phase.question;
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
    // Bumped by dispose() and by the next start(), so a learner who answers one
    // question and leaves doesn't keep eighteen downloads running on their
    // cellular data for a round that no longer exists.
    final generation = ++_prefetchGeneration;
    () async {
      // Let the live request for the CURRENT word get out first. The deck
      // warm-up starts at the same instant _beginQuestion() speaks, and while
      // both share one fetch for word[0], words 1-3 were competing with it for
      // bandwidth and Edge Function concurrency — making the very request the
      // learner is waiting on the slowest of the batch.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (generation != _prefetchGeneration) return;
      const batchSize = 3;
      for (var i = 0; i < words.length; i += batchSize) {
        if (generation != _prefetchGeneration) return; // round is over
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
          // The English example sentence, so tapping it on the reveal plays
          // instantly rather than racing a cold fetch. Always English: it is
          // the language being learned, and hearing the word inside a sentence
          // is the whole point of the clip.
          final example = w.glossFor('en').example;
          if (example.isNotEmpty) {
            await Voice.instance.prefetch(example,
                langCode: 'en',
                headword: w.word,
                headwordPos: w.pos,
                sayAs: w.say);
          }
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
        final next = remaining.value - _tickMs;
        if (next <= 0) {
          remaining.value = 0;
          _onTimeout(); // this one IS a state change, and does notify
        } else {
          // Only the countdown moved. Listeners of `remaining` (the progress
          // bar) repaint; nothing else rebuilds.
          remaining.value = next;
        }
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
    //
    // The countdown goes with it. FSRS grades on a four-point scale and Qulex
    // only knows right/wrong, so the clock is what fills the gap: an answer
    // given in the first two seconds and one scraped in at the buzzer are not
    // the same evidence about how well the word is known. Untimed modes pass
    // null and every correct answer there grades as Good. See Fsrs.gradeFor.
    store.recordAnswer(
      current.id,
      correct,
      DateTime.now().millisecondsSinceEpoch,
      clockLeft: timed ? (remainingMs / totalMs).clamp(0.0, 1.0) : null,
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
    // previousDay() does calendar arithmetic. `now.subtract(Duration(days: 1))`
    // subtracts 24 absolute hours, which names the wrong day on the morning
    // after a spring-forward and quietly reset the streak. See daily.dart.
    store.registerPlay(_ymd(now), _ymd(previousDay(now)));
  }

  String _ymd(DateTime d) => ymd(d);

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
    _prefetchGeneration++; // stop any deck warm-up still in flight
    remaining.dispose();
    super.dispose();
  }
}
