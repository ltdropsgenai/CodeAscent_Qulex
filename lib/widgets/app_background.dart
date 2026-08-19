import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme.dart';

/// Rotating photoreal study-scene backdrop with slow Ken Burns motion and a
/// crossfade to a new scene every ~20s. A three-band scrim keeps content
/// legible over any image; a solid base color + asset error fallback mean it
/// never blanks; it honours the OS "reduce motion" setting. [dim] deepens the
/// scrim for gameplay so answer options stay readable.
class AppBackground extends StatefulWidget {
  final bool dim;
  const AppBackground({super.key, this.dim = false});

  @override
  State<AppBackground> createState() => _AppBackgroundState();
}

const _kScenes = <String>[
  'assets/backgrounds/bg_01.png',
  'assets/backgrounds/bg_02.png',
  'assets/backgrounds/bg_03.png',
  'assets/backgrounds/bg_04.png',
  'assets/backgrounds/bg_05.png',
  'assets/backgrounds/bg_06.png',
  'assets/backgrounds/bg_07.png',
  'assets/backgrounds/bg_08.png',
  // Photographs from a trip to the Dominican Republic, graded to match the
  // eight above rather than dropped in as shot — see tools/prepare_backgrounds.py.
  // Tropical noon is the opposite of what this app needs behind cream text, so
  // each one is desaturated, warmed, crushed and exposure-matched to the same
  // mean brightness as the originals. bg_16 additionally uses a contre-jour
  // curve that collapses the two figures into silhouette: the people in these
  // are the author and his partner, and none of them should be identifiable.
  //
  // JPEG, not PNG. The eight above average 2MB each; these average 150KB and
  // are indistinguishable at these tones.
  'assets/backgrounds/bg_09.jpg',
  'assets/backgrounds/bg_10.jpg',
  'assets/backgrounds/bg_11.jpg',
  'assets/backgrounds/bg_12.jpg',
  'assets/backgrounds/bg_13.jpg',
  'assets/backgrounds/bg_14.jpg',
  'assets/backgrounds/bg_15.jpg',
  'assets/backgrounds/bg_16.jpg',
];

const Color _kBase = Color(0xFF07070A);

class _AppBackgroundState extends State<AppBackground>
    with TickerProviderStateMixin {
  late final AnimationController _kb; // Ken Burns (ping-pong)
  late final AnimationController _fade; // crossfade between scenes
  Timer? _roter;
  final math.Random _r = math.Random();

  late List<String> _order;
  int _pos = 0;
  late String _current;
  String? _incoming;
  bool _reduceMotion = false;
  bool _precached = false;

  @override
  void initState() {
    super.initState();
    _order = List.of(_kScenes)..shuffle(_r);
    _current = _order[0];
    _kb = AnimationController(vsync: this, duration: const Duration(seconds: 26))
      ..repeat(reverse: true);
    _fade = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_precached) {
      _precached = true;
      // Only the scene on screen and the one after it.
      //
      // This used to precache all eight. assets/backgrounds/ is ~16MB on disk
      // and each photo decodes to roughly 8MB of ARGB, so the image cache
      // filled to ~60MB during launch, on the UI isolate, competing with the
      // title sequence's first frames — which is where jank and low-memory
      // kills come from on cheaper Android hardware. The rotation is 20
      // seconds wide; there is no reason to hold scene eight in memory before
      // scene two has been shown.
      _warm(_order[0]);
      if (_order.length > 1) _warm(_order[1]);
    }
    final rm = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (rm != _reduceMotion) {
      _reduceMotion = rm;
      _applyMotion();
    }
  }

  void _applyMotion() {
    _roter?.cancel();
    if (_reduceMotion) {
      _kb.stop();
      _kb.value = 0.5;
      return;
    }
    if (!_kb.isAnimating) _kb.repeat(reverse: true);
    _roter = Timer.periodic(const Duration(seconds: 20), (_) => _advance());
  }

  void _warm(String asset) {
    if (!mounted) return;
    precacheImage(AssetImage(asset), context, onError: (_, __) {});
  }

  void _advance() {
    if (!mounted) return;
    final next = _order[(_pos + 1) % _order.length];
    // Warm the one after next while this crossfade plays, so the following
    // transition is just as smooth without holding the whole set resident.
    _warm(_order[(_pos + 2) % _order.length]);
    setState(() => _incoming = next);
    _fade
      ..reset()
      ..forward().whenComplete(() {
        if (!mounted) return;
        setState(() {
          _current = next;
          _incoming = null;
          _pos = (_pos + 1) % _order.length;
        });
      });
  }

  @override
  void dispose() {
    _roter?.cancel();
    _kb.dispose();
    _fade.dispose();
    super.dispose();
  }

  Widget _scene(String asset, {double opacity = 1.0}) {
    return AnimatedBuilder(
      animation: _kb,
      builder: (_, __) {
        final v = _reduceMotion ? 0.5 : _kb.value;
        final scale = 1.06 + 0.14 * v;
        final dx = (v - 0.5) * 22.0;
        final dy = (v - 0.5) * -16.0;
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..translate(dx, dy)
              ..scale(scale),
            child: Image(
              image: AssetImage(asset),
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: _kBase),
            _scene(_current),
            if (_incoming != null)
              AnimatedBuilder(
                animation: _fade,
                builder: (_, __) => _scene(_incoming!, opacity: _fade.value),
              ),
            // Subtle coral wash from the bottom ties photos to the brand.
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, 1.1),
                    radius: 1.2,
                    colors: [
                      QColors.coral.withOpacity(0.10),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            // Three-band legibility scrim.
            IgnorePointer(
              child: CustomPaint(painter: _Scrim(widget.dim), size: Size.infinite),
            ),
          ],
        ),
      ),
    );
  }
}

class _Scrim extends CustomPainter {
  final bool dim;
  _Scrim(this.dim);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    const base = _kBase;
    final topA = dim ? 0.92 : 0.80;
    final midA = dim ? 0.66 : 0.44;
    final botA = dim ? 0.96 : 0.90;

    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h * 0.32),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [base.withOpacity(topA), base.withOpacity(midA)],
        ).createShader(Rect.fromLTWH(0, 0, w, h * 0.32)),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, h * 0.32, w, h * 0.36),
      Paint()..color = base.withOpacity(midA),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, h * 0.68, w, h * 0.32),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [base.withOpacity(midA), base.withOpacity(botA)],
        ).createShader(Rect.fromLTWH(0, h * 0.68, w, h * 0.32)),
    );
  }

  @override
  bool shouldRepaint(covariant _Scrim old) => old.dim != dim;
}
