import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qulex/data/review_log.dart';
import 'package:qulex/data/word_repository.dart';
import 'package:qulex/l10n/strings.dart';
import 'package:qulex/screens/home_screen.dart';
import 'package:qulex/state/app_state.dart';
import 'package:qulex/theme.dart';

/// Lives in its own file rather than beside the rest of the personalisation
/// tests: HomeScreen's initState claims process-wide singletons (Voice,
/// CatalogueOta, SyncService), and sharing a file with tests that have already
/// driven a ProgressStore left the catalogue future never completing — the run
/// hung with no error and no failing expectation, which is the worst way for a
/// suite to break.
void main() {
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('qulex_nudge_');
    ReviewLog.instance.storageDirOverride = tmp;
  });

  tearDown(() async {
    ReviewLog.instance.storageDirOverride = null;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('the learner finds out', () {
    testWidgets('the banner appears once the log is deep enough, and once only',
        (tester) async {
      // No font loading here on purpose: nothing in this test measures text,
      // and rootBundle.load() inside testWidgets' fake-async zone never
      // completes — it hangs the run with no error at all.
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      // Real file I/O has to happen inside runAsync. testWidgets runs the body
      // in a fake-async zone that controls timers and microtasks but never
      // pumps dart:io completions, so an awaited readAsBytes() here simply
      // never returns — the test hangs with no error and no failure at all.
      await tester.runAsync(() async {
        final seed = List.generate(ReviewLog.fitThreshold + 5,
                (i) => 'w${i % 60},${1770000000000 + i * 60000},3,r')
            .join('\n');
        await File('${tmp.path}/reviews.csv').writeAsString('$seed\n');
        ReviewLog.instance.storageDirOverride = tmp;
        await ReviewLog.instance.load();
      });
      await appState.load();
      expect(appState.fsrsNudged, isFalse);

      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildQulexTheme(),
        home: HomeScreen(repository: WordRepository()),
      ));
      // Home decodes the catalogue on a real isolate; real time and frames have
      // to alternate for that to complete. See home_wide_test.
      var loaded = false;
      for (var attempt = 0; attempt < 40 && !loaded; attempt++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 250)));
        await tester.pump(const Duration(milliseconds: 100));
        loaded = find.byType(CircularProgressIndicator).evaluate().isEmpty;
      }
      expect(loaded, isTrue, reason: 'Home never finished loading');

      final banner = find.byKey(const ValueKey('tune-banner'));
      expect(banner, findsOneWidget,
          reason: 'a finished optimiser nobody is told about is not shipped');

      await tester.tap(
          find.text(Strings.t('en', 'personaliseNudgeDismiss')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(banner, findsNothing);
      expect(appState.fsrsNudged, isTrue,
          reason: 'dismissal has to persist, or it comes back every launch');
    });
  });
}
