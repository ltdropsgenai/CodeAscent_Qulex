import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qulex/data/progress_store.dart';
import 'package:qulex/game/daily.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProgressStore.load() survives damaged local state', () {
    test('truncated JSON: recovers, warns, and quarantines the bad value',
        () async {
      const bad = '{"abc":{"box":2,"seen":3,';
      SharedPreferences.setMockInitialValues({
        'qbit_word_progress_v1': bad,
        'qbit_profile_v1': '{"streak":9,"best":11,"last":"2026-08-18"}',
      });
      final s = ProgressStore();
      await s.load(); // used to throw FormatException out of the app's launch

      expect(s.loadWarnings, isNotEmpty);
      expect(s.wordCount, 0, reason: 'the unreadable section started fresh');
      expect(s.profile.streak, 9,
          reason: 'a damaged word map must not cost the profile too');

      final p = await SharedPreferences.getInstance();
      expect(p.getString('qbit_word_progress_v1'), isNull,
          reason: 'the bad value is moved out of the way');
      expect(p.getString('qbit_word_progress_v1__corrupt'), bad,
          reason: 'but kept, so it can still be recovered');
    });

    test('right JSON, wrong shape: recovers', () async {
      SharedPreferences.setMockInitialValues(
          {'qbit_word_progress_v1': '[1,2,3]'});
      final s = ProgressStore();
      await s.load();
      expect(s.loadWarnings, isNotEmpty);
      expect(s.wordCount, 0);
    });

    test('a damaged profile costs only the profile', () async {
      SharedPreferences.setMockInitialValues({
        'qbit_profile_v1': 'null',
        'qbit_word_progress_v1': '{"w1":{"box":3,"seen":5,"correct":4}}',
      });
      final s = ProgressStore();
      await s.load();
      expect(s.loadWarnings, isNotEmpty);
      expect(s.wordCount, 1, reason: 'word progress survived');
      expect(s.progressFor('w1').box, 3);
    });

    test('a damaged snapshot blob costs only the snapshots', () async {
      SharedPreferences.setMockInitialValues({
        'qbit_round_snapshots_v1': '"not a map"',
        'qbit_word_progress_v1': '{"w1":{"box":1,"seen":1}}',
      });
      final s = ProgressStore();
      await s.load();
      expect(s.roundSnapshot('fun', 'quickPlay'), isNull);
      expect(s.wordCount, 1);
    });

    test('one malformed word entry costs one word, not the map', () async {
      SharedPreferences.setMockInitialValues({
        'qbit_word_progress_v1':
            '{"good":{"box":4,"seen":9},"bad":"not an object",'
                '"good2":{"box":2,"seen":3}}',
      });
      final s = ProgressStore();
      await s.load();
      expect(s.wordCount, 2);
      expect(s.progressFor('good').box, 4);
      expect(s.progressFor('good2').box, 2);
      expect(s.loadWarnings.single, contains('1 word'));
    });

    test('clean state produces no warnings at all', () async {
      SharedPreferences.setMockInitialValues({
        'qbit_word_progress_v1': '{"w1":{"box":2,"seen":4,"correct":3}}',
        'qbit_profile_v1': '{"streak":3,"best":7,"last":"2026-08-18"}',
      });
      final s = ProgressStore();
      await s.load();
      expect(s.loadWarnings, isEmpty);
      expect(s.wordCount, 1);
      expect(s.profile.bestStreak, 7);
    });
  });

  group('streak dates', () {
    test('previousDay names the calendar day before, across a DST jump', () {
      // The control the old code also got right.
      expect(ymd(previousDay(DateTime(2026, 6, 15, 0, 30))), '2026-06-14');

      // The case it got wrong. Whatever the machine's zone, previousDay is
      // pure calendar arithmetic, so the answer is the 9th — never the 8th.
      expect(ymd(previousDay(DateTime(2026, 3, 10, 0, 30))), '2026-03-09');
      expect(ymd(previousDay(DateTime(2026, 11, 2, 0, 30))), '2026-11-01');
    });

    test('previousDay rolls months and years correctly', () {
      expect(ymd(previousDay(DateTime(2026, 3, 1, 0, 30))), '2026-02-28');
      expect(ymd(previousDay(DateTime(2028, 3, 1, 0, 30))), '2028-02-29');
      expect(ymd(previousDay(DateTime(2026, 1, 1, 0, 30))), '2025-12-31');
    });

    test('a streak survives the day after a spring-forward', () async {
      SharedPreferences.setMockInitialValues({});
      final s = ProgressStore();
      await s.load();
      s.profile.streak = 60;
      s.profile.lastPlayedYmd = '2026-03-09';

      final now = DateTime(2026, 3, 10, 0, 30); // 00:30, the morning after
      await s.registerPlay(ymd(now), ymd(previousDay(now)));

      expect(s.profile.streak, 61, reason: 'it used to reset to 1 here');
      expect(s.profile.bestStreak, 61);
    });
  });

  group('saves are coalesced', () {
    test('recording an answer no longer re-encodes the whole map', () async {
      SharedPreferences.setMockInitialValues({});
      final s = ProgressStore();
      await s.load();
      for (var i = 0; i < 4000; i++) {
        await s.recordAnswer('w$i', i.isEven, 1770000000000);
      }

      final sw = Stopwatch()..start();
      await s.recordAnswer('w0', true, 1770000000000);
      sw.stop();
      // ignore: avoid_print
      print('  >> 4000 words: one answer now costs ${sw.elapsedMicroseconds}us '
          '(was 5662us)');
      expect(sw.elapsedMicroseconds, lessThan(1500),
          reason: 'the encode happens once on flush, not once per answer');
    });

    test('flush actually writes, and in-memory state is never stale',
        () async {
      SharedPreferences.setMockInitialValues({});
      final s = ProgressStore();
      await s.load();
      await s.recordAnswer('w1', true, 1770000000000);

      // Readable immediately, before anything reaches disk.
      expect(s.progressFor('w1').seen, 1);

      final p = await SharedPreferences.getInstance();
      await s.flush();
      expect(p.getString('qbit_word_progress_v1'), contains('w1'));
    });

    test('flush is idempotent and safe when nothing is pending', () async {
      SharedPreferences.setMockInitialValues({});
      final s = ProgressStore();
      await s.load();
      await s.flush();
      await s.flush();
      await s.dispose();
    });
  });

  group('unfinished rounds expire', () {
    test('a round from four months ago is not offered', () async {
      SharedPreferences.setMockInitialValues({});
      final s = ProgressStore();
      await s.load();
      final old = DateTime.now().subtract(const Duration(days: 120));
      await s.saveRoundSnapshot('fun', 'quickPlay', {
        'deckIds': ['a', 'b'],
        'index': 4,
        'savedAtMillis': old.millisecondsSinceEpoch,
      });
      expect(s.roundSnapshot('fun', 'quickPlay'), isNull);
    });

    test('a round from this morning still is', () async {
      SharedPreferences.setMockInitialValues({});
      final s = ProgressStore();
      await s.load();
      await s.saveRoundSnapshot('fun', 'quickPlay', {
        'deckIds': ['a', 'b'],
        'index': 4,
        'savedAtMillis': DateTime.now().millisecondsSinceEpoch,
      });
      expect(s.roundSnapshot('fun', 'quickPlay'), isNotNull);
    });
  });
}
