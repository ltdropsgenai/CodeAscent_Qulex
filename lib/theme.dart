import 'package:flutter/material.dart';

/// Qulex palette — CodeAscent design language, Qulex's own coral / night-city world.
class QColors {
  static const bg = Color(0xFF07070A);
  static const coral = Color(0xFFFF5A3C);
  static const coralDeep = Color(0xFFE8442A);
  static const amber = Color(0xFFFFD23C);
  static const cream = Color(0xFFF4F1EA);
  static const ink = Color(0xFFECEDF0);
  static const muted = Color(0x8FFFFFFF); // ~56% white
  static const dim = Color(0x57FFFFFF); // ~34% white
  static const rule = Color(0x17FFFFFF); // ~9% white
  static const panel = Color(0x850C0C10); // translucent card over the photo

  static Color difficulty(String d) {
    switch (d) {
      case 'hard':
        return amber;
      default:
        return coral; // easy + medium share coral; hard stands out amber
    }
  }
}

/// Type helpers (Space Mono for labels, Spectral serif for hero, Inter for body).
///
/// The three families are BUNDLED (see `fonts:` in pubspec.yaml), not fetched.
/// They used to come from `google_fonts`, which downloads from
/// fonts.gstatic.com on first use — so a cold start rendered in Roboto for its
/// first few hundred milliseconds (most visibly during the title sequence, the
/// one moment the app is purely brand), and a first launch with no network
/// never got the brand faces at all.
///
/// The bundled .ttf files are the exact ones google_fonts was downloading, so
/// nothing about the rendering changes — it just happens before the first frame
/// instead of after it, deterministically, offline, with no third-party request
/// at startup.
///
/// Only the weights actually used are shipped:
///   Space Mono  400, 700          Spectral  500, 600, 400-italic
///   Inter       500, 600, 700
/// A request for an unshipped weight is resolved by the engine to the nearest
/// bundled one (CSS font-matching), which is exactly what google_fonts did —
/// e.g. the single `mono(weight: w500)` call resolves to 400 either way. If you
/// need a genuinely new weight, add the .ttf and declare it, rather than
/// letting the engine approximate it.
class QType {
  static const fontMono = 'Space Mono';
  static const fontSerif = 'Spectral';
  static const fontSans = 'Inter';

  /// Every font size in the app passes through here.
  ///
  /// Raising individual numbers by hand did not fix "the print is tiny on
  /// mobile", twice, because the problem was never one screen. It was the
  /// bottom of the scale everywhere: captions at 9-11pt, subtitles at 11.5,
  /// body prose at 13.5, against platform defaults of 17pt (iOS body) and
  /// 14sp (Material body-medium). One screen at a time was always going to
  /// miss the next one — About, Privacy and the Account screen were still
  /// untouched after the first pass.
  ///
  /// The correction is WEIGHTED, not a flat multiplier: +28% at the small end,
  /// tapering to nothing by 30pt. A flat factor big enough to rescue an 11pt
  /// label would have pushed the 44pt handoff word and the 58pt title mark out
  /// of layouts that were already tuned. It is also continuous, so the curve
  /// stays monotonic — an early version bucketed the ranges and made 14pt text
  /// render larger than 15pt text.
  ///
  /// This does not replace the OS text-size setting, which Flutter applies on
  /// top of whatever comes out of here. It fixes the default.
  static double scaled(double size) {
    final t = ((size - 12) / 18).clamp(0.0, 1.0);
    return size * (1.28 - 0.28 * t);
  }

  static TextStyle mono({
    double size = 12,
    FontWeight weight = FontWeight.w700,
    Color color = QColors.ink,
    double spacing = 2,
  }) =>
      TextStyle(
        fontFamily: fontMono,
        fontSize: scaled(size),
        fontWeight: weight,
        color: color,
        letterSpacing: spacing,
      );

  static TextStyle serif({
    double size = 40,
    FontWeight weight = FontWeight.w600,
    Color color = QColors.cream,
    double height = 1.0,
    FontStyle style = FontStyle.normal,
  }) =>
      TextStyle(
        fontFamily: fontSerif,
        fontSize: scaled(size),
        fontWeight: weight,
        color: color,
        height: height,
        fontStyle: style,
      );

  static TextStyle sans({
    double size = 16,
    FontWeight weight = FontWeight.w500,
    Color color = QColors.ink,
    double height = 1.3,
  }) =>
      TextStyle(
        fontFamily: fontSans,
        fontSize: scaled(size),
        fontWeight: weight,
        color: color,
        height: height,
      );
}

ThemeData buildQulexTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: QColors.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: QColors.coral,
      surface: QColors.bg,
    ),
  );
}
