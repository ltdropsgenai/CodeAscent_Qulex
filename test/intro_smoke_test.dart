import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qulex/screens/intro_screen.dart';
import 'package:qulex/data/word_repository.dart';

import 'font_loader.dart';
import 'package:qulex/widgets/word_drift.dart';

void main() {
  setUpAll(loadBrandFonts);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('WordDrift paints across strengths without throwing',
      (tester) async {
    for (final s in [0.0, 0.01, 0.3, 0.5, 0.999, 1.0]) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            height: 844,
            child: WordDrift(strength: s),
          ),
        ),
      ));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.takeException(), isNull, reason: 'strength=$s');
    }
  });

  testWidgets('WordDrift rotates through words over a long run',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SizedBox(width: 390, height: 844,
          child: WordDrift(strength: 1.0))),
    ));
    // 40 seconds of drift: every token should have been reseeded at least
    // twice (lives are 7-16s), which is the rotation the intro depends on.
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('IntroScreen plays its whole timeline without throwing',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: IntroScreen(repository: WordRepository()),
    ));
    // Walk the full 2800ms in 20ms steps, checking every frame. This is what
    // catches a degenerate gradient stop in the coral sweep.
    for (var i = 0; i < 139; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.takeException(), isNull, reason: 'frame $i');
    }
  });

  testWidgets('IntroScreen honours reduce-motion', (tester) async {
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: MaterialApp(home: IntroScreen(repository: WordRepository())),
    ));
    for (var i = 0; i < 44; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.takeException(), isNull, reason: 'frame $i');
    }
  });
}
