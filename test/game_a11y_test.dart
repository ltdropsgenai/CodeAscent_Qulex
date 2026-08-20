import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qulex/a11y.dart';
import 'package:qulex/data/progress_store.dart';
import 'package:qulex/data/word_repository.dart';
import 'package:qulex/game/track.dart';
import 'package:qulex/models/word.dart';
import 'package:qulex/screens/game_screen.dart';
import 'package:qulex/state/app_state.dart';
import 'package:qulex/theme.dart';

import 'font_loader.dart';

/// The game screen is the one place in the app where a layout failure costs
/// someone a round they cannot finish, and where colour-only feedback is the
/// difference between playable and not. It gets its own gate.
///
/// No AppBackground here on purpose: this test is about geometry and
/// announcements, and the backdrop's forever-repeating animation only makes
/// the pumping harder.
final bool kCapture = Platform.environment['QULEX_CAPTURE'] == '1';

Widget _frame(Widget child, {double textScale = 1.0}) => MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildQulexTheme(),
        home: Builder(
          builder: (context) => A11y.clampTextScale(
              context,
              RepaintBoundary(
                key: const ValueKey('shot'),
                child: ColoredBox(color: QColors.bg, child: child),
              )),
        ),
      ),
    );

void main() {
  setUpAll(loadBrandFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late List<Word> words;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    words = await WordRepository().loadAll();
  });

  Future<ProgressStore> pumpGame(WidgetTester tester, Size size,
      {double textScale = 1.0}) async {
    tester.view.physicalSize = Size(size.width * 3, size.height * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await appState.load();
    final store = ProgressStore();
    await store.load();
    await tester.pumpWidget(_frame(
      GameScreen(words: words, track: kTracks.first, store: store),
      textScale: textScale,
    ));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    return store;
  }

  testWidgets('a round survives every text size and every screen size',
      (tester) async {
    // Overflows throw in debug, so takeException() is the gate. The
    // combination that used to break things is small screen + large type.
    for (final size in [const Size(390, 844), const Size(1194, 834)]) {
      for (final scale in [1.0, 1.5, 2.0]) {
        await pumpGame(tester, size, textScale: scale);
        expect(tester.takeException(), isNull,
            reason: 'game screen at $size, ${scale}x');
      }
    }
  });

  testWidgets('the answer verdict is carried by words, not just colour',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pumpGame(tester, const Size(390, 844));

    // Before answering, the options are plain buttons with no verdict.
    expect(find.bySemanticsLabel(RegExp('Correct')), findsNothing);

    // Answer one. Whichever option is tapped, exactly one option must end up
    // announced as correct — right and wrong are drawn in coral and amber,
    // which is the worst possible pair for a red-green deficiency and says
    // nothing at all to a screen reader.
    expect(find.byKey(const ValueKey('opt-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('opt-0')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(find.bySemanticsLabel(RegExp(', Correct\$')), findsOneWidget,
        reason: 'the right answer must say so in words');
    handle.dispose();
  });

  testWidgets('progress and the clock are announceable, not just drawn',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pumpGame(tester, const Size(390, 844));

    // The tick strip and the timer bar are both pure colour on screen.
    expect(find.bySemanticsLabel('Question'), findsOneWidget);
    expect(find.bySemanticsLabel('Time left'), findsOneWidget);
    // Score and streak are bare digits next to a coloured dot.
    expect(find.bySemanticsLabel('Score'), findsOneWidget);
    expect(find.bySemanticsLabel('Streak'), findsOneWidget);
    handle.dispose();
  });
  testWidgets('capture a question at three sizes', (tester) async {
    // The vertical spread of a question used to come from two Spacers inside
    // an IntrinsicHeight. That construction was broken (see game_screen.dart),
    // so it had to be replaced — and replacing the thing that positions the
    // whole question is exactly the change that deserves a picture.
    await pumpGame(tester, const Size(390, 844));
    await expectLater(find.byKey(const ValueKey('shot')),
        matchesGoldenFile('frames/game_phone.png'));
    await pumpGame(tester, const Size(390, 844), textScale: 1.8);
    await expectLater(find.byKey(const ValueKey('shot')),
        matchesGoldenFile('frames/game_phone_large_type.png'));
    await pumpGame(tester, const Size(1194, 834));
    await expectLater(find.byKey(const ValueKey('shot')),
        matchesGoldenFile('frames/game_tablet.png'));
  }, skip: !kCapture);
}
