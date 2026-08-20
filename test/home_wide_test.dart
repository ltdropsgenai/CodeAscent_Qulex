import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qulex/a11y.dart';
import 'package:qulex/data/word_repository.dart';
import 'package:qulex/layout.dart';
import 'package:qulex/screens/home_screen.dart';
import 'package:qulex/state/app_state.dart';
import 'package:qulex/theme.dart';
import 'package:qulex/widgets/app_background.dart';

import 'font_loader.dart';

/// Home is the only screen that changes SHAPE on a wide display, so it is the
/// only one that needs a test proving the shape actually changes — and that
/// the phone layout it grew out of is untouched.
final bool kCapture = Platform.environment['QULEX_CAPTURE'] == '1';

Widget _frame(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildQulexTheme(),
      home: Builder(
        builder: (context) => A11y.clampTextScale(
          context,
          ColoredBox(
            color: QColors.bg,
            child: RepaintBoundary(
              key: const ValueKey('shot'),
              child: Stack(children: [
                const AppBackground(dim: false),
                child,
              ]),
            ),
          ),
        ),
      ),
    );

/// Waits for Home's FutureBuilder to actually resolve.
///
/// NOT pumpAndSettle: the backdrop's Ken Burns controller repeats forever, so
/// nothing ever settles. And not a single long runAsync either — the catalogue
/// is decoded by compute() on a real isolate, whose completion has to be
/// PUMPED to be seen, so real time and frames have to alternate. Waiting once
/// and then pumping captured the loading spinner, which is what a golden of a
/// screen that never loaded looks like.
Future<void> _settle(WidgetTester tester) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)));
    await tester.pump(const Duration(milliseconds: 100));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      // Loaded. Let the entry animations land.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return;
    }
  }
  fail('Home never finished loading the catalogue');
}

void main() {
  setUpAll(loadBrandFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Where the two panes' contents actually sit.
  ///
  /// The tagline is the last thing in the left-hand (identity) list; the QUICK
  /// PLAY heading is the first thing in the right-hand (play) list. In one
  /// column the heading is far BELOW the tagline. In two panes it is BESIDE
  /// it — further right, and no lower. That geometric relationship is the
  /// whole claim, and it is checkable without looking at a screenshot.
  ({Offset tagline, Offset play}) anchors(WidgetTester tester) {
    final tagline = find.byKey(const ValueKey('home-tagline'));
    final play = find.byKey(const ValueKey('home-play-heading'));
    expect(tagline, findsOneWidget);
    expect(play, findsOneWidget);
    return (
      tagline: tester.getTopLeft(tagline),
      play: tester.getTopLeft(play),
    );
  }

  /// Resizes the view and pumps, WITHOUT rebuilding HomeScreen.
  ///
  /// Deliberate: HomeScreen is built once and then the display changes shape
  /// under it, which is exactly what happens when someone rotates an iPad or
  /// drags a Split View divider. It is also the only thing that works — the
  /// screen's initState touches singletons (Voice, CatalogueOta) that do not
  /// survive being re-created inside one test binding, so a second
  /// pumpWidget(HomeScreen(...)) hangs on the catalogue future forever. That
  /// cost an hour; do not "simplify" it back.
  Future<void> resize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = Size(size.width * 3, size.height * 3);
    tester.view.devicePixelRatio = 3.0;
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('Home reflows between one column and two panes', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await appState.load();
    await tester.pumpWidget(_frame(HomeScreen(repository: WordRepository())));
    await _settle(tester);

    // --- phone: the single column it always had -----------------------------
    expect(QLayout.classFor(390), QSizeClass.compact);
    var a = anchors(tester);
    expect(a.play.dy, greaterThan(a.tagline.dy),
        reason: 'on a phone the play list is below, as it always was');
    expect(a.play.dx, closeTo(a.tagline.dx, 1),
        reason: 'and in the same column');

    // --- iPad landscape: two panes -----------------------------------------
    await resize(tester, const Size(1194, 834));
    expect(tester.takeException(), isNull);
    expect(QLayout.classFor(1194), QSizeClass.expanded);
    a = anchors(tester);
    expect(a.play.dx, greaterThan(a.tagline.dx + 200),
        reason: 'the play list moved into a second column');
    expect(a.play.dy, lessThan(a.tagline.dy),
        reason: 'and sits beside the identity block, not under it');

    // --- iPad portrait: still two panes -------------------------------------
    // 834pt is the MEDIUM size class, and it splits anyway: QLayout.isWide's
    // threshold is 760, not 1000, because an iPad in portrait plainly fits two
    // columns and reads worse as one long scroll.
    await resize(tester, const Size(834, 1112));
    expect(tester.takeException(), isNull);
    a = anchors(tester);
    expect(a.play.dx, greaterThan(a.tagline.dx + 150));

    // --- back to a phone: nothing is stuck in the wide layout ---------------
    await resize(tester, const Size(390, 844));
    a = anchors(tester);
    expect(a.play.dx, closeTo(a.tagline.dx, 1));

    // Captures ride along inside this same test rather than in one of their
    // own, for the singleton reason in resize()'s comment: a second
    // pumpWidget(HomeScreen(...)) anywhere in this file never loads.
    if (!kCapture) return;
    await expectLater(find.byKey(const ValueKey('shot')),
        matchesGoldenFile('frames/home_phone.png'));
    await resize(tester, const Size(834, 1112));
    await expectLater(find.byKey(const ValueKey('shot')),
        matchesGoldenFile('frames/home_tablet_portrait.png'));
    await resize(tester, const Size(1194, 834));
    await expectLater(find.byKey(const ValueKey('shot')),
        matchesGoldenFile('frames/home_tablet_landscape.png'));
  });
}
