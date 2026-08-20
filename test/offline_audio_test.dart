import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qulex/data/progress_store.dart';
import 'package:qulex/models/word.dart';
import 'package:qulex/services/offline_audio.dart';
import 'package:qulex/state/app_state.dart';

/// The offline download spends two things that are not ours: somebody's mobile
/// data, and ElevenLabs credits on first synthesis. Both are invisible when
/// they go wrong. These tests are about the guards, not the plumbing.
Word _w(String id) => Word.fromJson({
      'id': id,
      'lang': 'en',
      'word': id.replaceAll('w_', ''),
      'pos': 'noun',
      'freqRank': 1,
      'difficulty': 'easy',
      'tags': const ['everyday'],
      'audio': const {'en': null},
      'gloss': {
        'en': {
          'correct': 'a meaning for $id',
          'distractors': const ['x', 'y'],
          'example': const {'text': 'A sentence.', 'source': 'generated'},
        }
      },
    });

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await appState.load();
    OfflineAudio.instance.connectivityProbe = null;
  });

  group('what gets downloaded', () {
    late ProgressStore store;
    late List<Word> words;

    setUp(() async {
      store = ProgressStore();
      await store.load();
      words = List.generate(50, (i) => _w('w_$i'));
    });

    test('due words come before unseen ones', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      // Make w_40 due; everything else is untouched.
      await store.recordAnswer('w_40', true, now - 10 * 86400000);
      store.progressFor('w_40').dueAtMillis = now - 1000;

      final plan = OfflineAudio.upcomingWords(words, store.progressFor);
      expect(plan.first.id, 'w_40',
          reason: 'a review you owe today matters more than a word you have '
              'never met');
    });

    test('suspended words are never downloaded', () async {
      await store.markKnown('w_3');
      final plan = OfflineAudio.upcomingWords(words, store.progressFor);
      expect(plan.map((w) => w.id), isNot(contains('w_3')),
          reason: 'paying to synthesise audio for a word the learner has '
              'switched off is pure waste');
    });

    test('a run is capped however long the catalogue is', () {
      final huge = List.generate(20000, (i) => _w('w_$i'));
      final plan = OfflineAudio.upcomingWords(huge, store.progressFor);
      expect(plan.length, OfflineAudio.maxWordsPerRun);
      expect(plan.length, lessThan(1000),
          reason: 'the cap is a spend guard, not a performance one');
    });

    test('walking a huge catalogue does not scan all of it', () {
      // The loop breaks once it has comfortably more than one run's worth.
      // If that break is ever removed, this gets slow rather than wrong, and
      // slow on the launch path is how a top-up becomes a jank report.
      final huge = List.generate(100000, (i) => _w('w_$i'));
      final sw = Stopwatch()..start();
      OfflineAudio.upcomingWords(huge, store.progressFor);
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(200));
    });
  });

  group('the background top-up refuses unless everything lines up', () {
    late ProgressStore store;
    late List<Word> words;

    setUp(() async {
      store = ProgressStore();
      await store.load();
      words = List.generate(5, (i) => _w('w_$i'));
    });

    test('does nothing when the learner has not opted in', () async {
      await appState.setOfflineAudioAuto(false);
      OfflineAudio.instance.connectivityProbe = () async => true;
      expect(await OfflineAudio.instance.topUpIfAllowed(words), 0);
    });

    test('does nothing on a metered connection', () async {
      await appState.setOfflineAudioAuto(true);
      OfflineAudio.instance.connectivityProbe = () async => false;
      expect(await OfflineAudio.instance.topUpIfAllowed(words), 0,
          reason: 'cellular data is the learner\'s money, not ours');
    });

    test('treats unknown connectivity as metered', () async {
      await appState.setOfflineAudioAuto(true);
      OfflineAudio.instance.connectivityProbe =
          () async => throw StateError('no platform channel here');
      // topUpIfAllowed must swallow it and decline, not propagate.
      await expectLater(OfflineAudio.instance.topUpIfAllowed(words), completes);
    });

    test('the opt-in defaults to off', () async {
      SharedPreferences.setMockInitialValues({});
      await appState.load();
      expect(appState.offlineAudioAuto, isFalse,
          reason: 'downloading audio nobody asked for is how apps end up on '
              'a data-usage complaint');
    });

    test('the opt-in survives a restart', () async {
      await appState.setOfflineAudioAuto(true);
      await appState.load();
      expect(appState.offlineAudioAuto, isTrue);
    });
  });

  group('the download itself', () {
    test('refuses to run when voice is switched off', () async {
      if (appState.voiceOn) await appState.toggleVoice();
      final n = await OfflineAudio.instance.download([_w('w_1')]);
      expect(n, 0);
      expect(OfflineAudio.instance.progress.value.stoppedBecause, isNotNull,
          reason: 'a button that silently does nothing reads as broken');
      if (!appState.voiceOn) await appState.toggleVoice();
    });

    test('an empty plan finishes rather than hanging', () async {
      await expectLater(OfflineAudio.instance.download(const []), completion(0));
      expect(OfflineAudio.instance.isRunning, isFalse);
    });

    test('progress starts idle', () {
      final p = OfflineAudio.instance.progress.value;
      expect(p.running, isFalse);
      expect(p.fraction, 0);
    });

    test('fraction never divides by zero', () {
      const p = OfflineProgress(done: 0, total: 0);
      expect(p.fraction, 0);
      expect(p.idle, isTrue);
    });
  });
}
