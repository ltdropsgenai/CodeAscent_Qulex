import 'dart:async';
import 'package:flutter/material.dart';
import '../data/word_repository.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'splash_screen.dart';

/// Brief animated first-launch beat: the "Qbit" wordmark assembles (letters
/// settle in, then the coral slash swings across the Q), and once it has
/// settled the "Word Mastery" subtitle scrolls up beneath it. After it plays
/// out (or the player taps to skip) we hand off to [SplashScreen] for Qbit's
/// bragging-rights pitch. This screen itself never sets `seenIntro` — only
/// reaching the end of the splash screen does — so a killed app before that
/// point simply replays this intro on next launch instead of losing it.
class IntroScreen extends StatefulWidget {
  final WordRepository repository;
  const IntroScreen({super.key, required this.repository});

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  Timer? _autoAdvance;
  bool _advanced = false;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1800));
    _c.forward();
    // Hold a beat once settled, then move on automatically.
    _autoAdvance = Timer(const Duration(milliseconds: 2500), _advance);
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
    Navigator.of(context).pushReplacement(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 420),
      pageBuilder: (_, __, ___) =>
          SplashScreen(repository: widget.repository),
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final locale = appState.locale;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _advance, // tap anywhere to skip straight to the pitch screen
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              // Mark fades + scales in over the first ~45% of the timeline.
              final markT =
                  Curves.easeOutBack.transform((_c.value / 0.45).clamp(0.0, 1.0));
              // Coral slash swings into place right after, ~30%-65%.
              final slashT = Curves.easeOutCubic
                  .transform(((_c.value - 0.30) / 0.35).clamp(0.0, 1.0));
              // Subtitle scrolls up + fades in over the back half.
              final subT = Curves.easeOut
                  .transform(((_c.value - 0.55) / 0.45).clamp(0.0, 1.0));

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Opacity(
                    opacity: markT.clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale: 0.6 + 0.4 * markT.clamp(0.0, 1.0),
                      child: _AssemblingMark(slashT: slashT),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ClipRect(
                    child: Opacity(
                      opacity: subT,
                      child: Transform.translate(
                        offset: Offset(0, (1 - subT) * 16),
                        child: Text(
                          Strings.t(locale, 'wordMastery'),
                          style: QType.mono(
                              size: 12, color: QColors.coral, spacing: 4),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The "Qbit" mark assembling: cream letters settle first (scale + fade),
/// then the coral slash swings in over the Q from a wide angle down to its
/// resting mark — echoing the static [Wordmark] used everywhere else.
class _AssemblingMark extends StatelessWidget {
  final double slashT; // 0 -> 1
  const _AssemblingMark({required this.slashT});

  static const double _size = 58;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Text('Qbit',
            style: QType.serif(
                size: _size, color: QColors.cream, weight: FontWeight.w600)),
        Positioned(
          left: _size * 0.40,
          top: _size * 0.02,
          child: Opacity(
            opacity: slashT.clamp(0.0, 1.0),
            child: Transform.rotate(
              // Swings in from a wide angle down to the resting -0.9 rad tilt.
              angle: -0.9 - (1 - slashT) * 1.7,
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
    );
  }
}
