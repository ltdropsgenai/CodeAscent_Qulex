import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Qbit palette — CodeAscent design language, Qbit's own coral / night-city world.
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
class QType {
  static TextStyle mono({
    double size = 12,
    FontWeight weight = FontWeight.w700,
    Color color = QColors.ink,
    double spacing = 2,
  }) =>
      GoogleFonts.spaceMono(
        fontSize: size,
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
      GoogleFonts.spectral(
        fontSize: size,
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
      GoogleFonts.inter(
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
      );
}

ThemeData buildQbitTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: QColors.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: QColors.coral,
      surface: QColors.bg,
    ),
  );
}
