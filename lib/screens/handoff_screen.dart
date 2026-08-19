import 'dart:async';

import 'package:flutter/material.dart';

import '../data/word_repository.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'home_screen.dart';

/// The beat between the title sequence and the app.
///
/// IntroScreen used to hand straight to [HomeScreen], which meant the sequence
/// ended and a fully-populated screen of tracks and counters appeared — an edit
/// with nothing between the two halves. This is that something: one line,
/// flashed, on the same dark ground the title sequence closes on, so the two
/// read as one continuous open rather than a cut.
///
/// ON "FLASHING". The word flashes three times over 1,150ms — 2.6 Hz. That
/// number is deliberate and should not be raised casually: content flashing
/// more than three times per second is a recognised seizure trigger
/// (WCAG 2.3.1), and this runs full-screen on every cold start. The dim end of
/// the cycle also stops at 8% rather than 0, so it pulses rather than strobing
/// between black and white. Anyone who has asked their OS for reduced motion
/// gets no flashing at all — just the line, held briefly.
///
/// The timing lives on the widget rather than its state so a test can assert
/// the RATE, which is the thing that actually matters: shortening the run is
/// exactly as dangerous as adding a fourth flash, and only their ratio shows
/// it. See handoff_test.dart.
class HandoffScreen extends StatefulWidget {
  final WordRepository repository;

  /// Built once by the caller and passed through to [HomeScreen], rather than
  /// letting Home make its own, so the two screens cannot end up on different
  /// catalogues if a download lands between them.
  const HandoffScreen({super.key, required this.repository});

  /// 1,150ms of flashing plus 250ms held solid. The route transition that
  /// follows supplies the fade, so nothing is spent fading out here.
  static const Duration fullRun = Duration(milliseconds: 1400);

  /// Reduce-motion stays short on purpose: someone who asked the OS for less
  /// animation does not want a longer interstitial, just a calmer one.
  static const Duration reducedRun = Duration(milliseconds: 700);

  static const int flashCount = 3;
  static const double flashWindow = 1150 / 1400;

  /// The number the accessibility ceiling is actually about.
  static double get flashesPerSecond =>
      flashCount / (fullRun.inMilliseconds * flashWindow / 1000);

  /// Opacity of the line at controller position [t] (0..1).
  ///
  /// Pulled out as a pure function so the properties that matter — never fully
  /// dark, exactly three peaks, solid at the end — can be checked directly
  /// instead of inferred from pixels.
  static double flashOpacity(double t, {bool reduceMotion = false}) {
    if (reduceMotion) return 1.0;
    if (t >= flashWindow) return 1.0;
    final phase = (t / flashWindow * flashCount) % 1.0;
    double v;
    if (phase < 0.18) {
      v = Curves.easeOut.transform(phase / 0.18);
    } else if (phase < 0.55) {
      v = 1.0;
    } else if (phase < 0.73) {
      v = 1.0 - Curves.easeIn.transform((phase - 0.55) / 0.18);
    } else {
      v = 0.0;
    }
    // Floors at 8%: a pulse, not a strobe between black and white.
    return 0.08 + 0.92 * v;
  }

  @override
  State<HandoffScreen> createState() => _HandoffScreenState();
}

class _HandoffScreenState extends State<HandoffScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  Timer? _autoAdvance;
  bool _advanced = false;
  bool _reduceMotion = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: HandoffScreen.fullRun);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (_started) return;
    _started = true;
    final run =
        _reduceMotion ? HandoffScreen.reducedRun : HandoffScreen.fullRun;
    _c.duration = run;
    _c.forward();
    _autoAdvance = Timer(run, _advance);
  }

  @override
  void dispose() {
    _autoAdvance?.cancel();
    _c.dispose();
    super.dispose();
  }

  void _advance() {
    if (_advanced || !mounted) return;
    _advanced = true;
    _autoAdvance?.cancel();
    Navigator.of(context).pushReplacement(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 420),
      pageBuilder: (_, __, ___) => HomeScreen(repository: widget.repository),
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final locale = appState.locale;
    final text = Strings.t(locale, 'letsLearn');
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _advance, // never trap someone who has seen it enough times
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // The app's backdrop is a photograph, and this screen has exactly
            // one job: put two words in front of someone for a second and a
            // half. Cream serif over a sunlit stone wall is legible but has to
            // compete; dropping the photo back to a third of its strength
            // leaves the word as the only thing on screen, on the same
            // near-black the title sequence ends on, so the two read as one
            // shot rather than two.
            const ColoredBox(color: Color(0xBF07070C)),
            Center(
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) {
                  final o = HandoffScreen.flashOpacity(_c.value,
                      reduceMotion: _reduceMotion);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Opacity(
                        opacity: o,
                        child: Text(
                          text,
                          textAlign: TextAlign.center,
                          style: QType.serif(size: 44, color: QColors.cream),
                        ),
                      ),
                      const SizedBox(height: 18),
                      // A coral rule that widens under the word, echoing the
                      // line that closes the title sequence. It does not
                      // flash — one moving thing at a time.
                      Opacity(
                        opacity: (_c.value * 3).clamp(0.0, 1.0),
                        child: Container(
                          width: 56 + 76 * Curves.easeOut.transform(_c.value),
                          height: 2,
                          color: QColors.coral,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
