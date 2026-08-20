import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qulex/data/progress_store.dart';
import 'package:qulex/data/review_log.dart';
import 'package:qulex/game/srs.dart';

/// The review log is the half of FSRS personalisation that has to ship first
/// and does nothing visible, which makes it exactly the kind of code that
/// quietly stops working without anyone noticing for six months. These tests
/// are the noticing.
void main() {
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('qulex_revlog_');
    ReviewLog.instance.storageDirOverride = tmp;
    await ReviewLog.instance.clear();
  });

  tearDown(() async {
    ReviewLog.instance.storageDirOverride = null;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<ProgressStore> freshStore() async {
    final s = ProgressStore();
    await s.load();
    return s;
  }

  group('through the store', () {
    test('every answer is banked, and survives a reload', () async {
      final s = await freshStore();
      var now = 1770000000000;
      for (var i = 0; i < 12; i++) {
        await s.recordAnswer('w$i', i.isEven, now, clockLeft: 0.5);
        now += 60000;
      }
      await s.flush();
      await ReviewLog.instance.flush();

      final back = await ReviewLog.instance.readAll();
      expect(back.length, 12);
      expect(back.first.wordId, 'w0');
      // Even indices were answered correctly at half the clock -> Good;
      // odd ones were wrong -> Again.
      expect(back[0].grade, Grade.good);
      expect(back[1].grade, Grade.again);
    });

    test('the phase recorded is the one BEFORE the answer', () async {
      // The whole point: an optimiser replays the input to the scheduler, not
      // its output. A word's first ever answer must be logged as new, even
      // though recordAnswer leaves it in learning.
      final s = await freshStore();
      await s.recordAnswer('w', true, 1770000000000, clockLeft: 0.5);
      await ReviewLog.instance.flush();
      var log = await ReviewLog.instance.readAll();
      expect(log.single.phase, 'n', reason: 'first sight is new, not learning');
      expect(s.progressFor('w').state, SrsState.learning);

      await s.recordAnswer('w', true, 1770000600000, clockLeft: 0.5);
      await ReviewLog.instance.flush();
      log = await ReviewLog.instance.readAll();
      expect(log.last.phase, 'l', reason: 'second answer came from learning');
    });

    test('a round of answers costs no writes until the store flushes',
        () async {
      final s = await freshStore();
      final f = File('${tmp.path}/reviews.csv');
      for (var i = 0; i < 10; i++) {
        await s.recordAnswer('w$i', true, 1770000000000, clockLeft: 0.5);
      }
      // Buffered: still nothing on disk.
      expect(f.existsSync() && f.lengthSync() > 0, isFalse,
          reason: 'an answer must not cost a file write');
      expect(ReviewLog.instance.count, 10,
          reason: 'but the count includes what is buffered');

      await ReviewLog.instance.flush();
      expect(f.readAsLinesSync().where((l) => l.isNotEmpty).length, 10);
    });
  });

  group('durability', () {
    test('a corrupt half-written line costs one review, not the file',
        () async {
      final f = File('${tmp.path}/reviews.csv');
      await f.writeAsString('w_a,1770000000000,3,r\n'
          'w_b,177000\n' // killed mid-append
          'w_c,1770000002000,1,l\n');
      final back = await ReviewLog.instance.readAll();
      expect(back.length, 2);
      expect(back.map((e) => e.wordId), ['w_a', 'w_c']);
    });

    test('a nonsense grade is dropped rather than replayed', () async {
      final f = File('${tmp.path}/reviews.csv');
      await f.writeAsString('w_a,1770000000000,9,r\n'
          'w_b,1770000001000,0,r\n'
          'w_c,1770000002000,4,r\n');
      final back = await ReviewLog.instance.readAll();
      expect(back.map((e) => e.wordId), ['w_c']);
    });

    test('entries come back oldest first even if the file is not', () async {
      // A clock change or a compaction could disturb order, and a replay that
      // runs out of order is silently wrong rather than loudly broken.
      final f = File('${tmp.path}/reviews.csv');
      await f.writeAsString('w_late,1770000009000,3,r\n'
          'w_early,1770000001000,3,r\n');
      final back = await ReviewLog.instance.readAll();
      expect(back.map((e) => e.wordId), ['w_early', 'w_late']);
    });

    test('a missing log is empty, not an exception', () async {
      await ReviewLog.instance.clear();
      expect(await ReviewLog.instance.readAll(), isEmpty);
      expect(ReviewLog.instance.count, 0);
    });

    test('an unwritable directory does not break answering', () async {
      // The log is best-effort by design: losing it costs future fitting
      // accuracy and must never cost the learner their round.
      ReviewLog.instance.storageDirOverride =
          Directory('/definitely/not/a/real/path');
      final s = await freshStore();
      await expectLater(
          s.recordAnswer('w', true, 1770000000000, clockLeft: 0.5),
          completes);
      await expectLater(ReviewLog.instance.flush(), completes);
      ReviewLog.instance.storageDirOverride = tmp;
    });
  });

  group('the cap', () {
    test('drops the oldest fifth and keeps the newest', () async {
      final f = File('${tmp.path}/reviews.csv');
      final sink = StringBuffer();
      for (var i = 0; i < ReviewLog.maxEntries + 10; i++) {
        sink.writeln('w$i,${1770000000000 + i * 1000},3,r');
      }
      await f.writeAsString(sink.toString());

      // Force the compaction path by logging one more through the real API.
      await ReviewLog.instance.load();
      ReviewLog.instance.record(
          wordId: 'w_newest',
          atMillis: 1790000000000,
          grade: Grade.good,
          phaseBefore: SrsState.review);
      await ReviewLog.instance.flush();

      final back = await ReviewLog.instance.readAll();
      expect(back.length, lessThanOrEqualTo(ReviewLog.maxEntries));
      expect(back.length, greaterThan(ReviewLog.maxEntries ~/ 2));
      // Recent history is what predicts near-term forgetting, so the tail is
      // what gets dropped.
      expect(back.last.wordId, 'w_newest');
      expect(back.first.wordId, isNot('w0'));
    });
  });

  group('the fit threshold', () {
    test('is not met by a handful of reviews', () async {
      final s = await freshStore();
      for (var i = 0; i < 20; i++) {
        await s.recordAnswer('w$i', true, 1770000000000, clockLeft: 0.5);
      }
      expect(ReviewLog.instance.canFit, isFalse,
          reason: 'fitting on 20 reviews produces noise, not personalisation');
    });

    test('is met once there is real history', () async {
      final s = await freshStore();
      for (var i = 0; i < ReviewLog.fitThreshold; i++) {
        await s.recordAnswer('w${i % 50}', i % 3 != 0, 1770000000000 + i * 1000,
            clockLeft: 0.5);
      }
      expect(ReviewLog.instance.canFit, isTrue);
      expect(ReviewLog.instance.count, ReviewLog.fitThreshold);
    });
  });

  group('what an optimiser will need', () {
    test('a card\'s history replays in order with usable intervals', () async {
      final s = await freshStore();
      const day = 86400000;
      var now = 1770000000000;
      for (var i = 0; i < 6; i++) {
        await s.recordAnswer('w_target', true, now, clockLeft: 0.5);
        now = s.progressFor('w_target').dueAtMillis;
      }
      // Some noise from other words, to prove per-card filtering works.
      await s.recordAnswer('w_other', false, now);
      await ReviewLog.instance.flush();

      final mine = (await ReviewLog.instance.readAll())
          .where((e) => e.wordId == 'w_target')
          .toList();
      expect(mine.length, 6);
      for (var i = 1; i < mine.length; i++) {
        final gap = mine[i].atMillis - mine[i - 1].atMillis;
        expect(gap, greaterThan(0), reason: 'intervals must be derivable');
      }
      // The later gaps should be days apart, which is what makes the log worth
      // fitting against at all.
      expect(mine.last.atMillis - mine[mine.length - 2].atMillis,
          greaterThan(day));
    });

    test('clearing it really clears it', () async {
      final s = await freshStore();
      await s.recordAnswer('w', true, 1770000000000, clockLeft: 0.5);
      await ReviewLog.instance.flush();
      expect(ReviewLog.instance.count, 1);

      await ReviewLog.instance.clear();
      expect(ReviewLog.instance.count, 0);
      expect(await ReviewLog.instance.readAll(), isEmpty);
    });
  });
}
