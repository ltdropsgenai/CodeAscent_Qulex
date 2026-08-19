import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qulex/data/word_repository.dart';
import 'package:qulex/l10n/strings.dart';
import 'package:qulex/screens/handoff_screen.dart';
import 'package:qulex/state/app_state.dart';

import 'font_loader.dart';

void main() {
  setUpAll(loadBrandFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('flash timing', () {
    test('stays under the 3-per-second accessibility ceiling', () {
      // WCAG 2.3.1. This runs full-screen on every cold start, so it is not a
      // theoretical limit. Asserting the RATE rather than the two constants
      // that produce it is the point: halving the run length is exactly as
      // dangerous as adding a fourth flash, and only their ratio shows it.
      expect(HandoffScreen.flashesPerSecond, lessThan(3.0));
    });

    test('flashes exactly three times and never goes fully dark', () {
      var peaks = 0;
      var wasHigh = false;
      var minSeen = 1.0;
      for (var i = 0; i <= 2000; i++) {
        final o = HandoffScreen.flashOpacity(i / 2000);
        minSeen = o < minSeen ? o : minSeen;
        final high = o > 0.9;
        if (high && !wasHigh) peaks++;
        wasHigh = high;
      }
      // Three flashes, then the final solid hold reads as a fourth rise.
      expect(peaks, 4);
      expect(minSeen, greaterThanOrEqualTo(0.08));
    });

    test('ends solid, so the screen is not mid-blink when it hands over', () {
      expect(HandoffScreen.flashOpacity(1.0), 1.0);
      expect(HandoffScreen.flashOpacity(0.95), 1.0);
    });

    test('does not flash at all under reduce-motion', () {
      for (var i = 0; i <= 20; i++) {
        expect(HandoffScreen.flashOpacity(i / 20, reduceMotion: true), 1.0);
      }
    });
  });

  testWidgets('shows the localized line and hands over on its own', (tester) async {
    await appState.load();
    await tester.pumpWidget(MaterialApp(
      home: HandoffScreen(repository: WordRepository()),
    ));
    expect(find.text(Strings.t('en', 'letsLearn')), findsOneWidget);

    // Runs to the end and pushes on without anyone touching it.
    await tester.pump(HandoffScreen.fullRun);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(Strings.t('en', 'letsLearn')), findsNothing);
  });

  testWidgets('a tap skips it', (tester) async {
    await appState.load();
    await tester.pumpWidget(MaterialApp(
      home: HandoffScreen(repository: WordRepository()),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byType(HandoffScreen));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(Strings.t('en', 'letsLearn')), findsNothing);
  });

  testWidgets('every locale has a line to show', (tester) async {
    for (final l in Strings.supported) {
      final s = Strings.t(l, 'letsLearn');
      expect(s, isNotEmpty);
      expect(s, isNot('letsLearn'), reason: '$l is missing the key');
    }
  });
}
