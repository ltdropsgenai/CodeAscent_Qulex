import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qulex/data/word_repository.dart';
import 'package:qulex/screens/intro_screen.dart';
import 'package:qulex/theme.dart';

import 'font_loader.dart';

/// Captures the title sequence at each beat of its 2800ms timeline.
///
/// The drift field seeds itself from the launch time in the app — that is the
/// feature — so this pins it with [IntroScreen.driftSeed]. Without that the
/// image differs every run and no comparison is possible; with it, these
/// goldens are a genuine regression check on the whole sequence.

/// Set QULEX_CAPTURE=1 to run this.
///
/// Skipped by default, and deliberately. Golden images are rasterized by the
/// HOST's font engine, so a file generated on Linux does not match the same
/// widget rendered on Windows or on a CI mac — the pixels differ for reasons
/// that say nothing about whether the code is right. Leaving these in the
/// default run means `flutter test` fails on every machine that didn't happen
/// to generate the images.
///
/// They are a developer tool for LOOKING at the output, not a regression gate:
///
///     QULEX_CAPTURE=1 flutter test --update-goldens test/intro_frames_test.dart
///
/// on Windows PowerShell:
///
///     $env:QULEX_CAPTURE=1; flutter test --update-goldens test/intro_frames_test.dart
///
/// then open test/frames/. The behaviour these images illustrate is covered
/// properly by intro_smoke_test.dart and hero_word_test.dart, which assert on
/// measurements rather than pixels and pass anywhere.
final bool kCapture = Platform.environment['QULEX_CAPTURE'] == '1';

void main() {
  setUpAll(loadBrandFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('capture intro frames', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildQulexTheme(),
      home: ColoredBox(
        color: QColors.bg,
        child: RepaintBoundary(
          key: const ValueKey('shot'),
          child: IntroScreen(
            repository: WordRepository(),
            driftSeed: 20260819,
          ),
        ),
      ),
    ));

    const marks = <int>[150, 450, 800, 1150, 1500, 1750, 2000, 2400];
    var elapsed = 0;
    for (final m in marks) {
      await tester.pump(Duration(milliseconds: m - elapsed));
      elapsed = m;
      await expectLater(
        find.byKey(const ValueKey('shot')),
        matchesGoldenFile('frames/intro_${m.toString().padLeft(4, '0')}ms.png'),
      );
    }
  }, skip: !kCapture);
}
