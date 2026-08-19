
import 'package:flutter/services.dart';

/// Loads the app's bundled brand faces into the test font collection.
///
/// `flutter test` does not register a package's declared fonts automatically —
/// text falls back to the test face, whose glyphs are full em squares. That is
/// fine for layout smoke tests and useless for anything that measures text:
/// "osseointegration" comes out 736pt wide at 46pt instead of roughly half
/// that. Anything asserting on fit has to load the real files first.
Future<void> loadBrandFonts() async {
  Future<void> load(String family, List<String> assets) async {
    final loader = FontLoader(family);
    for (final a in assets) {
      loader.addFont(rootBundle.load(a));
    }
    await loader.load();
  }

  await load('Spectral', const [
    'assets/fonts/Spectral-Medium.ttf',
    'assets/fonts/Spectral-SemiBold.ttf',
    'assets/fonts/Spectral-Italic.ttf',
  ]);
  await load('Space Mono', const [
    'assets/fonts/SpaceMono-Regular.ttf',
    'assets/fonts/SpaceMono-Bold.ttf',
  ]);
  await load('Inter', const [
    'assets/fonts/Inter-Medium.ttf',
    'assets/fonts/Inter-SemiBold.ttf',
    'assets/fonts/Inter-Bold.ttf',
  ]);
}
