import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qulex/data/progress_store.dart';
import 'package:qulex/data/review_log.dart';
import 'package:qulex/game/fsrs_optimiser.dart';
import 'package:qulex/game/srs.dart';
import 'package:qulex/l10n/strings.dart';
import 'package:qulex/screens/settings_screen.dart';
import 'package:qulex/state/app_state.dart';

/// Personalisation was, until this file existed, a feature that had been tested
/// in pieces and never run. fsrs_optimiser_test.dart proves the maths; this
/// proves the parts around it — that answers reach the optimiser through the
/// real store, that the answer it gives survives leaving the screen, and that a
/// learner is ever told the feature exists.
void main() {
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('qulex_personalise_');
    ReviewLog.instance.storageDirOverride = tmp;
    await ReviewLog.instance.clear();
    Fsrs.useDefaults();
  });

  tearDown(() async {
    ReviewLog.instance.storageDirOverride = null;
    Fsrs.useDefaults();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('the whole chain', () {
    test('answers played through the store reach the optimiser', () async {
      final store = ProgressStore();
      await store.load();

      // Enough volume to clear the threshold, spread over enough distinct words
      // that a holdout can be held back. The pattern is arbitrary on purpose:
      // the claim is that the pipeline CARRIES the data, not that this
      // particular learner is fittable.
      var now = 1770000000000;
      for (var round = 0; round < 12; round++) {
        for (var w = 0; w < 40; w++) {
          await store.recordAnswer('w$w', (round + w) % 3 != 0, now,
              clockLeft: 0.5);
          now += 45000;
        }
        now += 86400000;
      }
      await store.flush();
      await ReviewLog.instance.flush();

      expect(ReviewLog.instance.count, greaterThanOrEqualTo(480));
      expect(ReviewLog.instance.canFit, isTrue);

      final history = await ReviewLog.instance.readAll();
      expect(history.length, ReviewLog.instance.count);

      final result = FsrsOptimiser.fit(history);
      // It may fit or it may decline — both are honest outcomes for a synthetic
      // learner. What must NOT happen is a decline for lack of data, because
      // that would mean the log never reached the optimiser.
      expect(result.reason, isNot(FitDecline.tooFewReviews));
      expect(result.reason, isNot(FitDecline.noHistory));
      expect(result.reviewsUsed, greaterThanOrEqualTo(ReviewLog.fitThreshold));

      if (result.improved) {
        final before = Fsrs.recallStability(5.0, 6.0, 0.9, Grade.good);
        await appState.setFsrsWeights(result.weights);
        expect(appState.fsrsPersonalised, isTrue);
        expect(Fsrs.isPersonalised, isTrue);
        final after = Fsrs.recallStability(5.0, 6.0, 0.9, Grade.good);
        expect(after, isNot(closeTo(before, 1e-9)),
            reason: 'adopting a fit that changed nothing is not a fit');
      }
    });

    test('the banked count does not go backwards when a flush races load',
        () async {
      // load() reads the file and writes a count; flush() appends and adds to
      // the same count. Started together, the read's stale total used to land
      // last and silently erase the batch — and the count is what gates the
      // whole feature.
      final seed =
          List.generate(300, (i) => 'w$i,1770000000000,3,r').join('\n');
      await File('${tmp.path}/reviews.csv').writeAsString('$seed\n');
      ReviewLog.instance.storageDirOverride = tmp; // resets the loaded state

      for (var i = 0; i < 25; i++) {
        ReviewLog.instance.record(
            wordId: 'x$i',
            atMillis: 1770000000000 + i,
            grade: Grade.good,
            phaseBefore: SrsState.review);
      }
      // Deliberately NOT awaited before the flush — that is the race.
      final loading = ReviewLog.instance.load();
      final flushing = ReviewLog.instance.flush();
      await Future.wait([loading, flushing]);

      expect(ReviewLog.instance.count, 325);
      expect(ReviewLog.instance.banked.value, 325);
    });
  });

  group('the result survives leaving Settings', () {
    test('every outcome round-trips through the stored note', () {
      for (final d in FitDecline.values) {
        final note = fitNote(FitResult(
            baselineLoss: 1, fittedLoss: 1, reviewsUsed: 0, reason: d));
        final text = fitNoteText('en', note);
        expect(text, isNotNull, reason: '$d produced no sentence');
        expect(text, isNot(note), reason: '$d showed its code instead of words');
        expect(text, Strings.t('en', switch (d) {
          FitDecline.tooFewReviews => 'personaliseDeclineFew',
          FitDecline.noHistory => 'personaliseDeclineNone',
          FitDecline.tooFewWords => 'personaliseDeclineWords',
          FitDecline.noGradable => 'personaliseDeclineUngradable',
          FitDecline.noImprovement => 'personaliseDeclineWorse',
        }));
      }
      final ok = fitNote(FitResult(
          weights: List<double>.from(Fsrs.w),
          baselineLoss: 1.0,
          fittedLoss: 0.8,
          reviewsUsed: 823));
      expect(ok, 'ok:20:823');
      expect(fitNoteText('en', ok), contains('20%'));
      expect(fitNoteText('en', ok), contains('823'));
    });

    test('is translated, not stored as English', () {
      final note = fitNote(const FitResult(
          baselineLoss: 1,
          fittedLoss: 1,
          reviewsUsed: 0,
          reason: FitDecline.noImprovement));
      expect(fitNoteText('es', note),
          Strings.t('es', 'personaliseDeclineWorse'));
      expect(fitNoteText('es', note), isNot(fitNoteText('en', note)));
    });

    test('an unreadable note falls back rather than showing an error', () {
      // A note written by a newer build, or half-written, must leave the row
      // looking normal instead of turning it into a diagnostic.
      expect(fitNoteText('en', null), isNull);
      expect(fitNoteText('en', ''), isNull);
      expect(fitNoteText('en', 'no:somethingFromTheFuture'), isNull);
      expect(fitNoteText('en', 'garbage'), isNull);
      expect(fitNoteText('en', 'ok:only:two:many'), isNull);
    });
  });
}
