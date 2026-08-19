import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qulex/data/progress_store.dart';
import 'package:qulex/data/word_repository.dart';
import 'package:qulex/screens/handoff_screen.dart';
import 'package:qulex/screens/settings_screen.dart';
import 'package:qulex/state/app_state.dart';
import 'package:qulex/theme.dart';
import 'package:qulex/widgets/app_background.dart';

import 'font_loader.dart';

/// Developer tool for LOOKING at two screens, not a regression gate — same
/// deal as intro_frames_test.dart. Golden images are rasterized by the host's
/// font engine, so files generated on one machine never match another's.
///
///     QULEX_CAPTURE=1 flutter test --update-goldens test/ui_frames_test.dart
///
/// then open test/frames/.
final bool kCapture = Platform.environment['QULEX_CAPTURE'] == '1';

Widget _frame(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildQulexTheme(),
      home: ColoredBox(
        color: QColors.bg,
        child: RepaintBoundary(
          key: const ValueKey('shot'),
          // The real app paints every screen over one full-bleed backdrop
          // (see main.dart). Capturing without it would flatter the type:
          // small text is hardest to read over a photograph, not over black.
          child: Stack(children: [
            const AppBackground(dim: false),
            child,
          ]),
        ),
      ),
    );

void main() {
  setUpAll(loadBrandFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('capture settings', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await appState.load();
    final store = ProgressStore();
    await store.load();

    await tester.pumpWidget(_frame(
      SettingsScreen(store: store, words: const []),
    ));
    // The backdrop is a real PNG and decodes off-thread. Without letting the
    // event loop actually run, the first capture lands on flat black — which
    // would be the wrong thing to judge type against, since a photograph is
    // the hard case and black is the easy one.
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 600)));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    await expectLater(find.byKey(const ValueKey('shot')),
        matchesGoldenFile('frames/settings_top.png'));

    // Second screenful — the promise and legal rows sit below the fold.
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -620));
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byKey(const ValueKey('shot')),
        matchesGoldenFile('frames/settings_bottom.png'));
  }, skip: !kCapture);

  testWidgets('capture the handoff flashes', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await appState.load();
    await tester.pumpWidget(_frame(
      HandoffScreen(repository: WordRepository()),
    ));

    // Across the 5000ms run: the arrival, all three flash cycles, and the
    // long hold where the drift field and the widening rule carry it.
    const marks = <int>[
      120, 400, 620, 900, 1200, 1450, 2000, 2800, 3600, 4800
    ];
    var elapsed = 0;
    for (final m in marks) {
      await tester.pump(Duration(milliseconds: m - elapsed));
      elapsed = m;
      await expectLater(
        find.byKey(const ValueKey('shot')),
        matchesGoldenFile('frames/handoff_${m.toString().padLeft(4, '0')}ms.png'),
      );
    }
  }, skip: !kCapture);
}
