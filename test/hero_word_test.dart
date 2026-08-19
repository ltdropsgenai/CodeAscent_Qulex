import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qulex/theme.dart';
import 'package:qulex/widgets/ui.dart';

import 'font_loader.dart';

/// The width HeroWord actually gets on the game screen: a 390pt phone, minus
/// the 20pt page padding either side, minus the 14pt gap and the ~44pt speaker
/// button.
const double kGameWidth = 390 - 40 - 14 - 44;

Future<void> _pump(WidgetTester tester, String word,
    {double width = kGameWidth, TextScaler scaler = TextScaler.noScaling}) {
  return tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: scaler),
      child: Scaffold(
        backgroundColor: QColors.bg,
        body: Center(child: SizedBox(width: width, child: HeroWord(word))),
      ),
    ),
  ));
}

/// Measured off the actual rendered box, which is exactly what the screenshot
/// showed: a one-line headword is about one line-height tall, a wrapped one is
/// about two.
int _lineCount(WidgetTester tester) {
  final t = tester.widget<Text>(find.byType(Text));
  final lineHeight = t.style!.fontSize! * (t.style!.height ?? 1.0);
  final rendered = tester.getSize(find.byType(Text)).height;
  return (rendered / lineHeight).round();
}

double _fontSize(WidgetTester tester) =>
    tester.widget<Text>(find.byType(Text)).style!.fontSize!;

void main() {
  setUpAll(loadBrandFonts);

  testWidgets('the word from the report no longer breaks across lines',
      (tester) async {
    await _pump(tester, 'osseointegration');
    expect(_lineCount(tester), 1,
        reason: 'used to render as "osseointegratio" + an orphaned "n"');
    expect(_fontSize(tester), lessThan(46));
    expect(_fontSize(tester), greaterThan(24));
  });

  testWidgets('short words keep the full 46pt', (tester) async {
    await _pump(tester, 'lucid');
    expect(_fontSize(tester), 46);
    expect(_lineCount(tester), 1);
  });

  testWidgets('the longest headwords in the catalogue all fit on one line',
      (tester) async {
    // The actual longest single-token headwords in assets/words.json
    // (15,363 of the 16,808 entries are single tokens; the longest is 20
    // characters).
    const longest = [
      'institutionalization',
      'magnetohydrodynamics',
      'countertransference',
      'extraterritoriality',
      'lymphoproliferative',
      'transubstantiation',
      'Klangfarbenmelodie',
      'osseointegration',
    ];
    for (final w in longest) {
      await _pump(tester, w);
      expect(_lineCount(tester), 1, reason: w);
      expect(tester.takeException(), isNull, reason: w);
    }
  });

  testWidgets('a phrase wraps at the space instead of shrinking away',
      (tester) async {
    // A real catalogue entry, 33 characters across three tokens.
    await _pump(tester, 'spike-timing-dependent plasticity');
    expect(_lineCount(tester), lessThanOrEqualTo(2));
    expect(_fontSize(tester), greaterThanOrEqualTo(46 * 0.62),
        reason: 'a phrase has a break opportunity, so it uses it');

    await _pump(tester, 'grand jeté');
    expect(_lineCount(tester), 1);
    expect(_fontSize(tester), 46);
  });

  testWidgets('still fits when the OS text size is turned up', (tester) async {
    await _pump(tester, 'osseointegration',
        scaler: const TextScaler.linear(1.35));
    expect(_lineCount(tester), 1,
        reason: 'the measurement has to include the text scaler');
  });

  testWidgets('a single token never ellipsises', (tester) async {
    // The bug this catches: measuring QType.serif directly instead of the
    // style Text actually renders (Material's default body style adds
    // letterSpacing), which made long words fit on paper and ellipsise on
    // screen.
    for (final w in [
      'institutionalization',
      'magnetohydrodynamics',
      'osseointegration',
    ]) {
      await _pump(tester, w);
      final t = tester.widget<Text>(find.byType(Text));
      final tp = TextPainter(
        text: TextSpan(text: w, style: t.style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: double.infinity);
      expect(tp.width, lessThanOrEqualTo(kGameWidth),
          reason: '$w renders at ${t.style!.fontSize} and must fit un-clipped');
    }
  });

  testWidgets('nothing overflows its box', (tester) async {
    for (final w in ['a', 'osseointegration', 'electroencephalography']) {
      await _pump(tester, w);
      expect(tester.takeException(), isNull, reason: w);
    }
  });
}
