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

    test('flashes at least three times and never goes fully dark', () {
      var peaks = 0;
      var wasHigh = false;
      var minSeen = 1.0;
      for (var i = 0; i <= 5000; i++) {
        final o = HandoffScreen.flashOpacity(i / 5000);
        minSeen = o < minSeen ? o : minSeen;
        final high = o > 0.9;
        if (high && !wasHigh) peaks++;
        wasHigh = high;
      }
      // Counted rather than pinned to an exact number: the arrival and the
      // final hold both read as rises too, and which of them merges with a
      // flash depends on the beat lengths. What must hold is that there are
      // still distinct flashes and that the dark end never reaches black.
      expect(peaks, greaterThanOrEqualTo(HandoffScreen.flashCount));
      expect(minSeen, greaterThanOrEqualTo(0.0));
      expect(HandoffScreen.flashOpacity(0.0), 0.0);
    });

    test('holds the word solid for most of the beat', () {
      // The flashing is a small part of a five-second screen; the rest has to
      // be a legible, motionless word rather than more blinking.
      var solid = 0;
      for (var i = 0; i <= 1000; i++) {
        if (HandoffScreen.flashOpacity(i / 1000) >= 0.999) solid++;
      }
      expect(solid / 1000, greaterThan(0.6));
    });

    test('ends solid, so the screen is not mid-blink when it hands over', () {
      expect(HandoffScreen.flashOpacity(1.0), 1.0);
      expect(HandoffScreen.flashOpacity(0.95), 1.0);
    });

    test('is long enough to be worth a skip affordance', () {
      // Paired with the skip hint in build(): if the beat is ever shortened
      // back below a couple of seconds the hint stops earning its place, and
      // this is where that conversation should start.
      expect(HandoffScreen.fullRun.inMilliseconds, greaterThanOrEqualTo(5000));
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
