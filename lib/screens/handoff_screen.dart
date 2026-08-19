import 'dart:async';

import 'package:flutter/material.dart';

import '../data/word_repository.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/word_drift.dart';
import 'home_screen.dart';

/// The beat between the title sequence and the app.
///
/// IntroScreen used to hand straight to [HomeScreen], which meant the sequence
/// ended and a fully-populated screen of tracks and counters appeared — an edit
/// with nothing between the two halves. This is that something: one line,
/// flashed, on the same dark ground the title sequence closes on, so the two
/// read as one continuous open rather than a cut.
///
/// AT FIVE SECONDS this screen needs something to do. Three flashes take
/// 1,150ms; the remaining 3.8s of a motionless word would read as the app
/// having hung, which is the opposite of the problem this screen was added to
/// solve. So the vocabulary drift field from the title sequence keeps running
/// underneath for the whole beat — it is the same widget, so the two screens
/// share a texture as well as a background — the rule keeps widening the whole
/// way, and the skip hint appears once the flashing is done.
///
/// ON "FLASHING". The word flashes three times over 1,150ms — 2.6 Hz. That
/// number is deliberate and should not be raised casually: content flashing
/// more than three times per second is a recognised seizure trigger
/// (WCAG 2.3.1), and this runs full-screen on every cold start. The dim end of
/// the cycle also stops at 8% rather than 0, so it pulses rather than strobing
/// between black and white. Anyone who has asked their OS for reduced motion
/// gets no flashing at all — just the line, held for a shorter beat.
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

  /// How long the beat lasts. THIS is the dial — everything below is expressed
  /// as a fraction of it, so changing this one number restretches the whole
  /// sequence without breaking the flash rate.
  ///
  /// Five seconds is a long time to hold someone at a title card, and it is
  /// most of why the skip hint below exists. On top of the 3,800ms title
  /// sequence it puts roughly nine seconds between tapping the icon and
  /// reaching Home.
  static const Duration fullRun = Duration(milliseconds: 5000);

  /// Reduce-motion stays short on purpose: someone who asked the OS for less
  /// animation does not want a longer interstitial, just a calmer one.
  static const Duration reducedRun = Duration(milliseconds: 1200);

  /// The word arrives over this fraction, then flashes between [flashFrom] and
  /// [flashTo], then holds solid for the rest.
  static const double arriveTo = 0.06;
  static const double flashFrom = 0.06;
  static const double flashTo = 0.29; // 1,150ms at a 5,000ms run

  static const int flashCount = 3;

  /// The number the accessibility ceiling is actually about. Pinned to the
  /// WINDOW, not the run, so lengthening the beat slows nothing down and
  /// shortening it is what would trip the test.
  static double get flashesPerSecond =>
      flashCount /
      (fullRun.inMilliseconds * (flashTo - flashFrom) / 1000);

  /// Opacity of the line at controller position [t] (0..1).
  ///
  /// Pulled out as a pure function so the properties that matter — never fully
  /// dark, exactly three peaks, solid at the end — can be checked directly
  /// instead of inferred from pixels.
  static double flashOpacity(double t, {bool reduceMotion = false}) {
    if (reduceMotion) return 1.0;
    if (t < arriveTo) {
      // The word fades up before it starts flashing, so the sequence opens on
      // an arrival rather than on a blink.
      return Curves.easeOut.transform((t / arriveTo).clamp(0.0, 1.0));
    }
    if (t >= flashTo) return 1.0;
    final phase =
        ((t - flashFrom) / (flashTo - flashFrom) * flashCount) % 1.0;
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
            // one job: put two words in front of someone. Cream serif over a
            // sunlit stone wall is legible but has to compete; dropping the
            // photo back to a third of its strength leaves the word as the
            // only thing on screen, on the same near-black the title sequence
            // ends on, so the two read as one shot rather than two.
            const ColoredBox(color: Color(0xBF07070C)),

            // The same drift field the title sequence opens with, carried
            // through underneath. Kept well clear of the middle so it never
            // competes with the word, and skipped entirely under reduce-motion.
            if (!_reduceMotion)
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _c,
                  builder: (context, _) => WordDrift(
                    strength: Curves.easeOut
                        .transform((_c.value / 0.12).clamp(0.0, 1.0)),
                    clearCenter: 0.30,
                  ),
                ),
              ),

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
                        opacity: (_c.value / HandoffScreen.arriveTo)
                            .clamp(0.0, 1.0),
                        child: Container(
                          // Widens for the entire beat, easing out, so there
                          // is always one thing still moving.
                          width: 56 +
                              108 *
                                  Curves.easeInOutCubic.transform(_c.value),
                          height: 2,
                          color: QColors.coral,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),

            // Five seconds is long enough that someone on their tenth launch
            // needs to be told they can leave. Appears only after the flashing
            // has finished, so it never competes with the word.
            Positioned(
              left: 0,
              right: 0,
              bottom: 34,
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) => Opacity(
                  opacity: (((_c.value - HandoffScreen.flashTo) / 0.12)
                          .clamp(0.0, 1.0)) *
                      0.55,
                  child: Text(
                    Strings.t(locale, 'introSkipHint'),
                    textAlign: TextAlign.center,
                    style:
                        QType.mono(size: 10, color: QColors.dim, spacing: 3),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
