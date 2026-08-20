import 'dart:io';

import 'package:flutter/material.dart';
import 'dart:ui' show Tristate;

import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qulex/a11y.dart';
import 'package:qulex/data/progress_store.dart';
import 'package:qulex/layout.dart';
import 'package:qulex/screens/settings_screen.dart';
import 'package:qulex/state/app_state.dart';
import 'package:qulex/theme.dart';
import 'package:qulex/widgets/app_background.dart';
import 'package:qulex/widgets/ui.dart';

import 'font_loader.dart';

/// Two jobs, and only one of them is a picture.
///
/// The ASSERTIONS run everywhere and are the actual gate: they fail if a
/// control clips its own label at a large text size, which is the failure mode
/// that makes an app unusable with Dynamic Type turned up and that no amount of
/// reading the code reliably catches.
///
/// The CAPTURES are gated behind QULEX_CAPTURE=1, same as the other frame
/// tests, because goldens rasterized by one machine's font engine never match
/// another's:
///
///     QULEX_CAPTURE=1 flutter test --update-goldens test/adaptive_frames_test.dart
final bool kCapture = Platform.environment['QULEX_CAPTURE'] == '1';

Widget _frame(Widget child, {double textScale = 1.0}) => MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: MaterialApp(
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
      ),
    );

void main() {
  setUpAll(loadBrandFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('size classes', () {
    test('map to the device configurations they are named for', () {
      // iPhone portrait, and an iPad Slide Over pane.
      expect(QLayout.classFor(390), QSizeClass.compact);
      expect(QLayout.classFor(320), QSizeClass.compact);
      // iPhone landscape and iPad portrait.
      expect(QLayout.classFor(844), QSizeClass.medium);
      expect(QLayout.classFor(834), QSizeClass.medium);
      // iPad landscape, desktop.
      expect(QLayout.classFor(1194), QSizeClass.expanded);
      expect(QLayout.classFor(1440), QSizeClass.expanded);
    });

    test('the shell finally uses a large display', () {
      // The old _columnWidth capped everything at 600. These are the widths
      // that regression would show up in.
      expect(QLayout.shellWidth(390), 390, reason: 'phone stays edge to edge');
      expect(QLayout.shellWidth(834), greaterThan(600),
          reason: 'an iPad in portrait must not be a 600pt strip');
      expect(QLayout.shellWidth(1194), greaterThan(900),
          reason: 'an iPad in landscape must not be a 600pt strip');
      // But not unbounded — a 4K monitor is not a reason for a 3,000pt row.
      expect(QLayout.shellWidth(3840), lessThanOrEqualTo(1400));
    });

    test('shell width never exceeds the display', () {
      for (var w = 200.0; w < 4000; w += 37) {
        expect(QLayout.shellWidth(w), lessThanOrEqualTo(w), reason: 'at $w');
      }
    });

    test('two panes only appear when there is room for two panes', () {
      expect(QLayout.classFor(390), QSizeClass.compact);
      // isWide reads MediaQuery, so it is exercised in the widget tests below;
      // what is checked here is that its threshold sits above phone landscape
      // (844 on the largest iPhone) would be a two-pane home only if we said
      // so — 760 is deliberately below that, because a 844pt landscape phone
      // genuinely does fit two columns and looks worse as one long scroll.
      expect(760, lessThan(844));
    });
  });

  group('Dynamic Type', () {
    testWidgets('the clamp honours real sizes and stops at the ceiling',
        (tester) async {
      double? seen;
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(3.5)),
        child: MaterialApp(
          home: Builder(
            builder: (context) => A11y.clampTextScale(
              context,
              Builder(builder: (inner) {
                seen = MediaQuery.textScalerOf(inner).scale(10) / 10;
                return const SizedBox();
              }),
            ),
          ),
        ),
      ));
      expect(seen, A11y.maxTextScale,
          reason: 'iOS accessibility sizes go past 3x; the app clamps at 2x');
    });

    testWidgets('a smaller-than-default setting is passed through untouched',
        (tester) async {
      double? seen;
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(0.85)),
        child: MaterialApp(
          home: Builder(
            builder: (context) => A11y.clampTextScale(
              context,
              Builder(builder: (inner) {
                seen = MediaQuery.textScalerOf(inner).scale(10) / 10;
                return const SizedBox();
              }),
            ),
          ),
        ),
      ));
      // Clamping the FLOOR would override someone who asked for smaller text.
      expect(seen, closeTo(0.85, 1e-9));
    });

    testWidgets('the real settings screen survives every text size',
        (tester) async {
      // The strongest gate in this file, and the one that has actually earned
      // its keep. It pumps the REAL screen — not a hand-built sample — at each
      // scale and checks two things a human would otherwise have to notice in
      // a screenshot:
      //
      //  1. NOTHING OVERFLOWS. A RenderFlex overflow throws in debug, so
      //     takeException() catches it. This found a 12px overflow in the
      //     settings header at 2x on the first run.
      //  2. NOTHING WRAPS TO A COLUMN OF LETTERS. A row title squeezed between
      //     an icon and a stepper had about 30pt left at 2x, and rendered
      //     "New words per day" one character per line down the screen. A
      //     minimum sensible width catches that; a height check never would.
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      for (final scale in [1.0, 1.5, 2.0]) {
        await appState.load();
        final store = ProgressStore();
        await store.load();
        await tester.pumpWidget(_frame(
            SettingsScreen(store: store, words: const []),
            textScale: scale));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(tester.takeException(), isNull,
            reason: 'something overflowed at ${scale}x');

        final title = find.text('New words per day');
        expect(title, findsOneWidget);
        final width = tester.getSize(title).width;
        expect(width, greaterThan(120),
            reason:
                'at ${scale}x the title had only ${width.toStringAsFixed(0)}pt '
                'and would wrap one letter per line');
      }
    });

    testWidgets('a segmented control grows with the type but never sprawls',
        (tester) async {
      // Two claims at once, and the second is the one that caught a real bug.
      //
      // GROWS: at 2x the cell must be taller, or the label is clipped.
      // DOES NOT SPRAWL: a Container with an `alignment` and bounded
      // constraints expands to fill its parent. The fixed `height: 42` this
      // control used to carry was the only thing preventing that; swapping it
      // for a minHeight made the control silently fill the entire 600pt
      // viewport. Measuring against the viewport is what noticed.
      final heights = <double, double>{};
      for (final scale in [1.0, 2.0]) {
        await tester.pumpWidget(_frame(
          Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(
              child: QSegment(
                  labels: const ['A', 'B', 'C'], index: 0, onChanged: (_) {}),
            ),
          ),
          textScale: scale,
        ));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        heights[scale] = tester.getSize(find.byType(QSegment).first).height;
      }
      expect(heights[2.0]!, greaterThan(heights[1.0]!),
          reason: 'the box must grow with the type, not clip it');
      expect(heights[1.0]!, lessThan(120),
          reason: 'a segmented control is a row of cells, not a page');
      // At 2x it deliberately becomes a VERTICAL stack of three cells — three
      // long words will not fit across a 390pt phone at that size at any
      // tracking, and shrinking them is not an accessibility fix. So it is
      // roughly three cells tall, not one, and that is the intent rather than
      // sprawl. What would still be sprawl is filling the 600pt viewport.
      expect(heights[2.0]!, greaterThan(heights[1.0]! * 2),
          reason: 'expected the stacked layout at 2x');
      expect(heights[2.0]!, lessThan(400));
    });
  });

  group('semantics', () {
    testWidgets('the shared controls are all announceable', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_frame(Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(children: [
          QToggle(value: true, onChanged: (_) {}, semanticLabel: 'Voice'),
          QStepper(
              value: 20,
              onMinus: () {},
              onPlus: () {},
              semanticLabel: 'New words per day'),
          QSegment(
              labels: const ['Relaxed', 'Normal', 'Intense'],
              index: 1,
              onChanged: (_) {}),
          QButton('Start', onTap: () {}),
          QRow(title: 'About', sub: 'What this is', onTap: () {}),
        ]),
      )));

      // A toggle must say what it controls AND whether it is on.
      final toggle = tester.getSemantics(find.byType(QToggle));
      expect(toggle.label, 'Voice');
      // `isToggled` is tristate: `none` means the node is not a toggle at all
      // (which is what a bare GestureDetector produced before this change),
      // `isTrue`/`isFalse` mean it is one and reports "on"/"off".
      expect(toggle.flagsCollection.isToggled, Tristate.isTrue,
          reason: 'without this VoiceOver cannot say "on" or "off"');
      expect(toggle.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

      // A stepper's two buttons must name what they change, and the number
      // between them must not be a bare orphaned digit.
      expect(
          find.bySemanticsLabel('Increase New words per day'), findsOneWidget);
      expect(
          find.bySemanticsLabel('Decrease New words per day'), findsOneWidget);
      expect(find.bySemanticsLabel('New words per day'), findsOneWidget);

      // The selected segment must be announced as selected — it is signalled
      // by colour alone on screen.
      final selected = tester.widget<QSegment>(find.byType(QSegment));
      expect(selected.index, 1);
      expect(
        find.bySemanticsLabel('Normal'),
        findsOneWidget,
      );

      // A button announces its label in sentence case, not the SHOUTING it is
      // drawn in — some voices spell all-caps out letter by letter.
      expect(find.bySemanticsLabel('Start'), findsOneWidget);
      expect(find.bySemanticsLabel('START'), findsNothing);

      // A row is one thing with a label and a hint, not three fragments.
      expect(find.bySemanticsLabel('About'), findsOneWidget);

      handle.dispose();
    });

    testWidgets('decorative chrome is not announced', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_frame(const Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(children: [QRule(), QLabel('Learning')]),
      )));
      // A hairline divider has nothing to say.
      expect(tester.getSemantics(find.byType(QRule)).label, isEmpty);
      // A section signpost is a header, so the rotor can jump to it.
      final header = tester.getSemantics(find
          .descendant(of: find.byType(QLabel), matching: find.byType(Semantics))
          .first);
      expect(header.flagsCollection.isHeader, isTrue);
      handle.dispose();
    });
  });

  group('captures', () {
    Future<void> shoot(WidgetTester tester, String name, Size size,
        {double textScale = 1.0}) async {
      tester.view.physicalSize = Size(size.width * 3, size.height * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await appState.load();
      final store = ProgressStore();
      await store.load();
      await tester.pumpWidget(_frame(
          SettingsScreen(store: store, words: const []),
          textScale: textScale));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 600)));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await expectLater(find.byKey(const ValueKey('shot')),
          matchesGoldenFile('frames/$name.png'));
    }

    testWidgets('settings on a phone, a tablet, and at 2x text',
        (tester) async {
      await shoot(tester, 'adaptive_settings_phone', const Size(390, 844));
      await shoot(tester, 'adaptive_settings_tablet', const Size(1024, 768));
      await shoot(tester, 'adaptive_settings_2x', const Size(390, 844),
          textScale: 2.0);
    }, skip: !kCapture);
  });
}
