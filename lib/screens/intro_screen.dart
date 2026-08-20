import 'dart:async';

import 'package:flutter/material.dart';

import '../a11y.dart';

import '../data/word_repository.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/word_drift.dart';
import 'handoff_screen.dart';
import 'splash_screen.dart';

/// Qulex's launch title sequence, played on **every** cold start.
///
/// A field of vocabulary drifts up out of the dark, the "Qulex" wordmark
/// assembles over it, the coral slash swings onto the Q, a coral light sweeps
/// the mark, and the CodeAscent line rises underneath. About 2.8 seconds,
/// tappable-to-skip at any point.
///
/// It is coded, not filmed, on purpose: a real video file would add 8–15MB to
/// a bundle that is already ~41MB, need a decoder to spin up before the first
/// frame (the one moment where a stall is most visible), ship at one fixed
/// resolution and aspect, and be unable to carry live catalogue words. Every
/// frame here is drawn at the display's own size and costs nothing to
/// download. See [WordDrift] for the drift field.
///
/// Where it hands off depends on whether this is a first run: a brand-new
/// install continues into [SplashScreen]'s pitch, and everyone else goes to
/// [HandoffScreen] and then Home. This screen never sets `seenIntro` itself —
/// only finishing the pitch does — so an app killed mid-pitch simply sees it
/// again next launch instead of losing it.
class IntroScreen extends StatefulWidget {
  final WordRepository repository;

  /// Pins the drift field's randomness. Tests only — see [WordDrift.seed].
  final int? driftSeed;

  const IntroScreen({super.key, required this.repository, this.driftSeed});

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen>
    with SingleTickerProviderStateMixin {
  // Long enough to actually be a title sequence.
  //
  // The first version ran 2800ms and felt like it barely happened — but the
  // duration was never the real problem. initState kicked off a 24MB
  // json.decode of the word catalogue on this isolate to feed the drift field
  // real vocabulary. That parse measures ~1.2s on a fast desktop and more on a
  // phone, and json.decode is synchronous: no frames are produced while it
  // runs, yet the AnimationController and the auto-advance Timer both keep
  // counting wall-clock. So most of the sequence played to a frozen screen and
  // then advanced immediately. The catalogue warm-up is gone (the built-in
  // deck reads better anyway, and HomeScreen loads the catalogue itself), and
  // with the main isolate free the timeline below is what you actually see.
  static const _fullRun = Duration(milliseconds: 3800);

  // Reduce-motion stays short on purpose: someone who has asked the OS for
  // less animation does not want a longer one.
  static const _reducedRun = Duration(milliseconds: 900);

  late final AnimationController _c;
  Timer? _autoAdvance;
  bool _advanced = false;
  bool _reduceMotion = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    // Duration is set in didChangeDependencies, where reduce-motion is
    // readable; this just creates the controller.
    _c = AnimationController(vsync: this, duration: _fullRun);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = A11y.reduceMotion(context);
    if (_started) return;
    _started = true;
    // Started here rather than in initState so the run length can honour the
    // OS reduce-motion setting, which needs a MediaQuery to read.
    final run = _reduceMotion ? _reducedRun : _fullRun;
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
    // First run continues into the pitch; everyone else gets the one-line
    // handoff and then Home. Nothing routes straight to Home from here — the
    // cut from a title sequence to a populated dashboard was the thing that
    // read badly.
    final Widget next = appState.seenIntro
        ? HandoffScreen(repository: widget.repository)
        : SplashScreen(repository: widget.repository);
    Navigator.of(context).pushReplacement(PageRouteBuilder(
      transitionDuration: A11y.duration(context, const Duration(milliseconds: 420)),
      pageBuilder: (_, __, ___) => next,
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    ));
  }

  /// Maps the controller onto one segment of the timeline, eased.
  double _seg(double from, double to, Curve curve) =>
      curve.transform(((_c.value - from) / (to - from)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    final locale = appState.locale;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _advance, // tap anywhere to skip
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            // Beats, as fractions of _fullRun (3800ms):
            //   field up      0    - 380ms
            //   mark settles  190  - 1290ms
            //   slash swings  910  - 1750ms
            //   light sweeps  1370 - 2280ms
            //   line rises    1820 - 2580ms
            //   HOLD          2580 - 3500ms   <- the beat that was missing
            //   lift away     3500 - 3800ms
            final driftT = _seg(0.00, 0.10, Curves.easeOut);
            final markT = _seg(0.05, 0.34, Curves.easeOutBack);
            final slashT = _seg(0.24, 0.46, Curves.easeOutCubic);
            final sweepT = _seg(0.36, 0.60, Curves.easeInOutCubic);
            final subT = _seg(0.48, 0.68, Curves.easeOut);
            final hintT = _seg(0.42, 0.55, Curves.easeOut);
            // Everything lifts away together on the last beat, so the
            // cross-fade into the next screen starts from calm rather than
            // from a full-strength title card.
            final outT = _seg(0.92, 1.00, Curves.easeIn);
            final exit = 1.0 - outT * 0.35;

            return Stack(
              fit: StackFit.expand,
              children: [
                // The drift field sits behind everything and keeps a band
                // clear down the middle for the mark.
                Positioned.fill(
                  child: WordDrift(
                    strength: driftT * exit,
                    clearCenter: 0.26,
                    seed: widget.driftSeed,
                  ),
                ),

                Center(
                  child: Opacity(
                    opacity: (markT.clamp(0.0, 1.0) * exit).clamp(0.0, 1.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Transform.scale(
                          scale: 0.62 + 0.38 * markT.clamp(0.0, 1.0),
                          child: _BrandMoment(
                            slashT: slashT,
                            sweepT: _reduceMotion ? 0.0 : sweepT,
                            glowT: markT.clamp(0.0, 1.0),
                          ),
                        ),
                        const SizedBox(height: 18),
                        ClipRect(
                          child: Opacity(
                            opacity: subT,
                            child: Transform.translate(
                              offset: Offset(0, (1 - subT) * 16),
                              child: Text(
                                Strings.t(locale, 'wordMastery'),
                                style: QType.mono(
                                    size: 12,
                                    color: QColors.coral,
                                    spacing: 4),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // A quiet skip affordance, so nobody sits through it twice
                // wondering whether the app has hung.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 34,
                  child: Opacity(
                    opacity: (hintT * 0.55 * exit).clamp(0.0, 1.0),
                    child: Text(
                      Strings.t(locale, 'introSkipHint'),
                      textAlign: TextAlign.center,
                      style: QType.mono(
                          size: 10, color: QColors.dim, spacing: 3),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The "Qulex" mark assembling, with the coral slash swinging onto the Q, a
/// soft coral glow blooming behind it, and a coral light sweeping across the
/// letters — the moment the whole sequence exists for. Geometry is kept in
/// lockstep with the static [Wordmark] used everywhere else in the app.
class _BrandMoment extends StatelessWidget {
  final double slashT; // 0 -> 1, slash swings in
  final double sweepT; // 0 -> 1, light crosses the mark
  final double glowT; // 0 -> 1, glow blooms with the mark
  const _BrandMoment({
    required this.slashT,
    required this.sweepT,
    required this.glowT,
  });

  static const double _size = 58;

  @override
  Widget build(BuildContext context) {
    final slash = slashT.clamp(0.0, 1.0);
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        // Coral bloom behind the letters. Painted with a radial gradient
        // rather than a BoxShadow blur — a blur on a full-width box is one of
        // the more expensive things you can ask a low-end GPU to do on the
        // very first frames after launch.
        Positioned(
          left: -_size * 2.0,
          right: -_size * 2.0,
          top: -_size * 0.55,
          bottom: -_size * 0.55,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    QColors.coral.withOpacity(0.085 * glowT),
                    QColors.coral.withOpacity(0.030 * glowT),
                    Colors.transparent,
                  ],
                  // Falls off early so this reads as warm air around the
                  // mark rather than a disc sitting behind it.
                  stops: const [0.0, 0.28, 0.82],
                ),
              ),
            ),
          ),
        ),

        Stack(
          clipBehavior: Clip.none,
          children: [
            Text('Qulex',
                style: QType.serif(
                    size: _size,
                    color: QColors.cream,
                    weight: FontWeight.w600)),

            // The coral light. A moving bright stop in a linear gradient,
            // clipped to the letters' box and tilted — no shader compile, no
            // saveLayer, no blur.
            if (sweepT > 0.12 && sweepT < 0.88)
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipRect(
                    child: Transform.scale(
                      scale: 2.2,
                      child: Transform.rotate(
                        angle: -0.42,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: [
                                Colors.transparent,
                                QColors.cream.withOpacity(0.30),
                                QColors.coral.withOpacity(0.42),
                                Colors.transparent,
                              ],
                              stops: [
                                (sweepT * 1.7 - 0.52).clamp(0.0, 1.0),
                                (sweepT * 1.7 - 0.40).clamp(0.0, 1.0),
                                (sweepT * 1.7 - 0.32).clamp(0.0, 1.0),
                                (sweepT * 1.7 - 0.16).clamp(0.0, 1.0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // The slash swings from a wide angle down to its resting tilt.
            Positioned(
              left: _size * 0.40,
              top: _size * 0.02,
              child: Opacity(
                opacity: slash,
                child: Transform.rotate(
                  angle: -0.9 - (1 - slash) * 1.7,
                  child: Container(
                    width: _size * 0.44,
                    height: _size * 0.085,
                    decoration: BoxDecoration(
                      color: QColors.coral,
                      borderRadius: BorderRadius.circular(_size * 0.05),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
