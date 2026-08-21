import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../models/progress.dart';
import '../models/word.dart';
import '../state/app_state.dart';
import 'voice.dart';

/// Warms the on-device clip cache so a round sounds the same on a plane as it
/// does at home.
///
/// WHAT WAS ACTUALLY BROKEN. Qulex has never been silent offline — flutter_tts
/// covers the fallback, so an unreachable network costs you the good voice, not
/// the audio. But the good voice is most of the point of the pronunciation
/// work, and "it degrades to a robot" is a real gap against Anki and Lingvist,
/// both of which are simply usable offline. The machinery to fix it already
/// existed: Voice.prefetch warms one clip, and the game already calls it for
/// the deck it is about to deal. Nothing had ever pointed it at a scope bigger
/// than the next few questions.
///
/// So this is a small service around a large existing capability. It picks a
/// scope, walks it with bounded concurrency, and reports progress.
///
/// WHY THE SCOPE IS BOUNDED. Every unique text costs ElevenLabs credits on
/// first synthesis — once, globally, because the Edge Function caches by text
/// hash, but once. Downloading all 16,808 words plus glosses is a 2.5M credit
/// job and tens of thousands of requests. A learner does not need it: they need
/// what they are about to see. [OfflineScope] is deliberately small enough to
/// be honest about, and capped so a tap cannot start something unbounded.
enum OfflineScope {
  /// What is due now plus the next new words — one or two sessions' worth.
  upcoming,

  /// Everything in the selected track, capped.
  track,
}

/// Progress of a running download, or the absence of one.
@immutable
class OfflineProgress {
  final int done;
  final int total;
  final bool running;

  /// Set when the last run stopped early. Null on success or while running.
  final String? stoppedBecause;

  const OfflineProgress({
    this.done = 0,
    this.total = 0,
    this.running = false,
    this.stoppedBecause,
  });

  double get fraction => total == 0 ? 0 : (done / total).clamp(0.0, 1.0);
  bool get idle => !running && total == 0;
}

class OfflineAudio {
  OfflineAudio._();
  static final OfflineAudio instance = OfflineAudio._();

  /// Test seam. Returns true when the connection is unmetered.
  Future<bool> Function()? connectivityProbe;

  /// Master switch for bulk voice downloading. OFF since 21 Aug 2026.
  ///
  /// THE ARITHMETIC. One run plans [maxWordsPerRun] (600) words x three clips
  /// each — headword, definition, English example — which is 1,800 synthesis
  /// requests. The tts Edge Function allows MAX_CALLS_PER_DAY = 600. A single
  /// tap therefore spends three days of budget in one go, and everything past
  /// call 600 comes back 429. Voice.speak() cannot tell a 429 from any other
  /// failure, so it falls back to flutter_tts — and the learner's audio turns
  /// robotic for the rest of the UTC day, with no error anywhere, because
  /// Voice.prefetch() swallows its exceptions by design.
  ///
  /// That is not a hypothetical. On 21 Aug 2026 one tap recorded 1,809 calls
  /// against the 600 cap and the voice silently reverted.
  ///
  /// TURNED OFF RATHER THAN RESIZED, because the right number is not known
  /// yet. It depends on a decision nobody has made: whether headwords and
  /// definitions get warmed server-side (cache hits return before the budget
  /// check, so a warmed download costs nothing), or the cap is raised, or the
  /// run is chunked across days. Picking one at speed is how the 1,800-vs-600
  /// mismatch got here in the first place.
  ///
  /// NORMAL PLAY IS UNAFFECTED. GameController still warms each round's deck
  /// through Voice.prefetch — roughly 30-50 clips a round — and every clip it
  /// fetches is cached on device and plays offline afterwards. What is gone is
  /// only the bulk pre-download of words nobody has reached yet.
  ///
  /// To restore: flip this to true. Both entry points come back, and so does
  /// the Settings block. Do not do it without changing one of the two numbers
  /// above — offline_audio_test.dart asserts the mismatch and will tell you.
  static const bool bulkDownloadEnabled = false;

  /// What the tts Edge Function permits per caller per day.
  ///
  /// Mirrored from supabase/functions/tts/index.ts. Duplicated deliberately:
  /// the client had no idea what the server's limit was, which is precisely
  /// how it came to ask for three times it. A test compares the two.
  static const int serverCallsPerDay = 600;

  /// Clips requested per word by [_plan].
  static const int clipsPerWord = 3;

  /// The most a single download will ever touch.
  ///
  /// Not a performance guard — a correctness one. Each new clip is a request
  /// and, on first synthesis anywhere, real credits. A cap means a mis-tap
  /// costs a known amount rather than the catalogue.
  static const int maxWordsPerRun = 600;

  /// How many clips are in flight at once.
  ///
  /// Three, not thirty. The ceiling here is politeness to the Edge Function and
  /// to a phone radio, not throughput: the whole job runs in the background
  /// while somebody studies, and finishing four minutes sooner is worth less
  /// than not stalling the question they are on.
  static const int _concurrency = 3;

  final ValueNotifier<OfflineProgress> progress =
      ValueNotifier<OfflineProgress>(const OfflineProgress());

  bool _cancelled = false;

  bool get isRunning => progress.value.running;

  /// True when the OS reports an unmetered connection.
  ///
  /// Wi-Fi and ethernet count; cellular does not. VPNs report as their own
  /// type on some platforms and are treated as metered, which is the safe way
  /// round — spending someone's cellular allowance on audio they did not ask
  /// for is a worse failure than not topping up.
  Future<bool> onUnmeteredConnection() async {
    // The try wraps EVERYTHING, including the injected probe. Any failure to
    // determine the connection type has to mean "assume metered" — a throw
    // that escaped here would propagate out of a background timer and, worse,
    // the one time it matters is exactly when connectivity is misbehaving.
    try {
      final probe = connectivityProbe;
      if (probe != null) return await probe();
      final result = await Connectivity().checkConnectivity();
      return result.contains(ConnectivityResult.wifi) ||
          result.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return false; // unknown means no
    }
  }

  void cancel() => _cancelled = true;

  /// The words worth having audio for: everything due, then unseen ones.
  ///
  /// Lives here rather than in either caller because the Settings button and
  /// the background top-up MUST agree on what "upcoming" means. Two copies of
  /// this that drifted apart would look like the manual download did not work,
  /// since the automatic one would keep re-fetching a different set.
  static List<Word> upcomingWords(
      List<Word> words, WordProgress Function(String id) progressFor) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final due = <Word>[];
    final fresh = <Word>[];
    for (final w in words) {
      final wp = progressFor(w.id);
      if (wp.suspended) continue;
      if (wp.seen > 0 && wp.dueAtMillis <= now) {
        due.add(w);
      } else if (wp.seen == 0) {
        fresh.add(w);
      }
      // Stop walking a 16,808-entry list once there is comfortably more than
      // one run's worth.
      if (due.length + fresh.length >= maxWordsPerRun * 2) break;
    }
    return [...due, ...fresh].take(maxWordsPerRun).toList();
  }

  /// The texts a scope needs, in the order they matter.
  ///
  /// Both the headword and the meaning in the learner's own language, because
  /// classic mode speaks the meaning and every other mode speaks the word — a
  /// download that only covered one of them would leave half the round robotic
  /// and look like a bug.
  /// What a run would fetch, as text+language pairs. Exposed for tests: the
  /// planning is the part with judgement in it, and the downloading is
  /// plumbing.
  @visibleForTesting
  List<({String text, String lang})> planFor(List<Word> words, String locale) =>
      _plan(words, OfflineScope.upcoming, locale)
          .map((c) => (text: c.text, lang: c.lang))
          .toList();

  List<_Clip> _plan(List<Word> words, OfflineScope scope, String locale) {
    final out = <_Clip>[];
    for (final w in words.take(maxWordsPerRun)) {
      out.add(_Clip(w.word, w.lang, w));
      final gloss = w.glossFor(locale);
      if (gloss.correct.isNotEmpty) {
        out.add(_Clip(gloss.correct, locale, w));
      }
      // The ENGLISH example sentence, whatever the learner's own language.
      //
      // This is the clip that matters most and the one that was missing. A
      // headword spoken alone is a word in isolation; the thing a learner
      // actually needs — and the thing WordUp's film clips provide — is the
      // word inside connected speech, with the stress and linking that only
      // appear in a sentence. It is always English because English is what is
      // being learned; the native-language sentence is a comprehension aid and
      // is not worth the credits.
      final en = w.glossFor('en');
      if (en.example.isNotEmpty) {
        out.add(_Clip(en.example, 'en', w));
      }
    }
    return out;
  }

  /// Downloads the clips for [words], skipping anything already cached.
  ///
  /// Returns the number newly fetched. Safe to call when one is already
  /// running — the second call is ignored rather than doubling the traffic.
  Future<int> download(
    List<Word> words, {
    OfflineScope scope = OfflineScope.upcoming,
    String? locale,
  }) async {
    if (!bulkDownloadEnabled) return 0;
    if (isRunning) return 0;
    if (!appState.voiceOn) {
      progress.value = const OfflineProgress(
          stoppedBecause: 'Voice is switched off in Settings.');
      return 0;
    }

    _cancelled = false;
    final loc = locale ?? appState.locale;
    final plan = _plan(words, scope, loc);

    // Cached clips are not work. Counting them as work would show a progress
    // bar racing to 90% and then crawling, which reads as a bug.
    final todo = <_Clip>[];
    for (final c in plan) {
      if (_cancelled) break;
      final have = await Voice.instance.isCached(c.text,
          langCode: c.lang,
          headword: c.word.word,
          headwordPos: c.word.pos,
          sayAs: c.word.say);
      if (!have) todo.add(c);
    }

    if (todo.isEmpty) {
      progress.value = const OfflineProgress(done: 0, total: 0);
      return 0;
    }

    progress.value = OfflineProgress(done: 0, total: todo.length, running: true);

    var done = 0;
    var index = 0;
    var failures = 0;

    Future<void> worker() async {
      while (true) {
        if (_cancelled) return;
        final i = index++;
        if (i >= todo.length) return;
        final c = todo[i];
        try {
          await Voice.instance.prefetch(c.text,
              langCode: c.lang,
              headword: c.word.word,
              headwordPos: c.word.pos,
              sayAs: c.word.say);
        } catch (_) {
          failures++;
        }
        done++;
        progress.value =
            OfflineProgress(done: done, total: todo.length, running: true);
      }
    }

    await Future.wait(List.generate(_concurrency, (_) => worker()));

    // A run that failed nearly everything means the network went away, not
    // that a few clips are missing. Saying so beats a bar that reached 100%
    // having downloaded nothing.
    final mostlyFailed = failures > todo.length ~/ 2;
    progress.value = OfflineProgress(
      done: done,
      total: todo.length,
      running: false,
      stoppedBecause: _cancelled
          ? 'Stopped.'
          : (mostlyFailed ? 'Lost the connection — try again later.' : null),
    );
    return done - failures;
  }

  /// Quietly tops the cache up, but only on an unmetered connection.
  ///
  /// Called on a timer well after launch, never on the launch path. Returns 0
  /// and does nothing at all when the learner has not opted in, when the
  /// connection is metered, or when a manual download is already running —
  /// three separate reasons to do nothing, each of which would otherwise be a
  /// surprise on somebody's data bill.
  Future<int> topUpIfAllowed(List<Word> upcoming) async {
    // First, and before the opt-in check: this runs on a launch timer with
    // nobody watching, so a learner who switched the toggle on weeks ago would
    // otherwise keep re-spending the whole daily budget every launch without
    // ever touching the button. The stored preference is left alone so that
    // flipping [bulkDownloadEnabled] back restores their actual choice.
    if (!bulkDownloadEnabled) return 0;
    if (!appState.offlineAudioAuto) return 0;
    if (isRunning) return 0;
    if (!await onUnmeteredConnection()) return 0;
    return download(upcoming, scope: OfflineScope.upcoming);
  }
}

class _Clip {
  final String text;
  final String lang;
  final Word word;
  const _Clip(this.text, this.lang, this.word);
}
