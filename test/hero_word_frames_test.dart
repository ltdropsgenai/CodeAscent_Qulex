import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qulex/theme.dart';
import 'package:qulex/widgets/ui.dart';

import 'font_loader.dart';


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

  testWidgets('capture hero words', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 700 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    const words = [
      'lucid',
      'osseointegration',
      'institutionalization',
      'magnetohydrodynamics',
      'spike-timing-dependent plasticity',
    ];

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      // Scaffold, not a bare ColoredBox: Text with no Material ancestor is
      // drawn with Flutter's double-yellow "missing Material" debug underline,
      // which would make the capture unreadable.
      home: Scaffold(
        backgroundColor: QColors.bg,
        body: RepaintBoundary(
        key: const ValueKey('shot'),
        child: ColoredBox(
          color: QColors.bg,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final w in words) ...[
                  Text(w.toUpperCase(),
                      style: QType.mono(
                          size: 9, color: QColors.dim, spacing: 2)),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: HeroWord(w)),
                      const SizedBox(width: 14),
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: QColors.coral),
                        ),
                        child: const Icon(Icons.volume_up,
                            color: QColors.coral, size: 20),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Divider(color: QColors.rule, height: 1),
                  const SizedBox(height: 14),
                ],
              ],
            ),
          ),
        ),
      ),
      ),
    ));
    await tester.pump();
    await expectLater(find.byKey(const ValueKey('shot')),
        matchesGoldenFile('frames/hero_words.png'));
  }, skip: !kCapture);
}
