import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme.dart';

/// Animated cinematic backdrop: dark night-city gradient with a coral horizon
/// glow, faint skyline + window lights, drifting bokeh, and the Q-bit
/// particle-network motif. [dim] adds a focus scrim for the gameplay screen.
///
/// This is a code-drawn stand-in; for production you can swap in real
/// night-city photos (bundled like Lexicon's) behind the same scrim/particles.
class AppBackground extends StatefulWidget {
  final bool dim;
  const AppBackground({super.key, this.dim = false});

  @override
  State<AppBackground> createState() => _AppBackgroundState();
}

class _AppBackgroundState extends State<AppBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  final math.Random _r = math.Random(7);

  late final List<_Building> _buildings;
  late final List<_Light> _lights;
  late final List<_Node> _nodes;
  late final List<_Bokeh> _bokeh;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(seconds: 60))
      ..repeat();

    // 3 parallax skyline layers (normalized coords 0..1)
    final layers = [
      [0.60, 0.42, 0.06, 0.12],
      [0.68, 0.36, 0.045, 0.09],
      [0.76, 0.30, 0.035, 0.07],
    ];
    _buildings = [];
    _lights = [];
    for (var li = 0; li < layers.length; li++) {
      final baseY = layers[li][0];
      final maxH = layers[li][1];
      final wMin = layers[li][2];
      final wMax = layers[li][3];
      var x = -0.05;
      while (x < 1.05) {
        final w = wMin + _r.nextDouble() * (wMax - wMin);
        final h = maxH * (0.4 + _r.nextDouble() * 0.6);
        _buildings.add(_Building(x, baseY, w, h, li));
        if (li >= 1) {
          for (var wy = baseY + 0.006; wy < baseY + h - 0.006; wy += 0.008 + _r.nextDouble() * 0.006) {
            for (var wx = x + 0.006; wx < x + w - 0.006; wx += 0.010 + _r.nextDouble() * 0.006) {
              if (_r.nextDouble() < 0.5) {
                _lights.add(_Light(wx, wy, li, 0.15 + _r.nextDouble() * 0.45,
                    _r.nextDouble() * 6.28, _r.nextDouble() < 0.22 ? 1 : 0));
              }
            }
          }
        }
        x += w + _r.nextDouble() * 0.01;
      }
    }

    _nodes = List.generate(22, (_) => _Node(
          _r.nextDouble(),
          _r.nextDouble() * 0.55,
          _r.nextDouble() * 6.28,
          0.01 + _r.nextDouble() * 0.03,
          0.01 + _r.nextDouble() * 0.02,
        ));
    _bokeh = List.generate(8, (_) => _Bokeh(
          _r.nextDouble(),
          _r.nextDouble(),
          0.02 + _r.nextDouble() * 0.05,
          _r.nextDouble() * 6.28,
          _r.nextDouble() < 0.4 ? 1 : 0,
          0.02 + _r.nextDouble() * 0.04,
        ));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) => CustomPaint(
            painter: _BgPainter(_c.value, widget.dim, _buildings, _lights,
                _nodes, _bokeh),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

class _Building {
  final double x, y, w, h;
  final int layer;
  const _Building(this.x, this.y, this.w, this.h, this.layer);
}

class _Light {
  final double x, y, base, phase;
  final int layer, color;
  const _Light(this.x, this.y, this.layer, this.base, this.phase, this.color);
}

class _Node {
  final double bx, by, phase, ampx, ampy;
  const _Node(this.bx, this.by, this.phase, this.ampx, this.ampy);
}

class _Bokeh {
  final double x, y, r, phase, alpha;
  final int color;
  const _Bokeh(this.x, this.y, this.r, this.phase, this.color, this.alpha);
}

class _BgPainter extends CustomPainter {
  final double t;
  final bool dim;
  final List<_Building> buildings;
  final List<_Light> lights;
  final List<_Node> nodes;
  final List<_Bokeh> bokeh;

  _BgPainter(this.t, this.dim, this.buildings, this.lights, this.nodes,
      this.bokeh);

  static const _tau = 6.28318;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final rect = Offset.zero & size;

    // 1. sky gradient
    final sky = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF0A0A12), Color(0xFF08080E), Color(0xFF0C0910)],
        stops: [0, 0.46, 1],
      ).createShader(rect);
    canvas.drawRect(rect, sky);

    // 2. coral horizon glow
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [QColors.coral.withOpacity(0.16), Colors.transparent],
        stops: const [0, 1],
      ).createShader(Rect.fromCircle(
          center: Offset(w * 0.5, h * 1.0), radius: w * 0.9));
    canvas.drawRect(rect, glow);

    final drift = math.sin(t * _tau) * (w * 0.012);

    // 3. skyline
    for (final b in buildings) {
      final p = b.layer == 0 ? 0.15 : (b.layer == 1 ? 0.28 : 0.45);
      final col = b.layer == 0
          ? const Color(0xFF0D0D15)
          : (b.layer == 1 ? const Color(0xFF0A0A11) : const Color(0xFF08080D));
      canvas.drawRect(
        Rect.fromLTWH(b.x * w + drift * p, b.y * h, b.w * w, b.h * h),
        Paint()..color = col,
      );
    }

    // 4. window lights (twinkle)
    for (final l in lights) {
      final p = l.layer == 1 ? 0.28 : 0.45;
      final a = (l.base * (0.6 + 0.4 * math.sin(t * _tau * 2 + l.phase)))
          .clamp(0.0, 1.0);
      final c = l.color == 1
          ? QColors.coral
          : const Color(0xFFFFD2A0);
      canvas.drawRect(
        Rect.fromLTWH(l.x * w + drift * p, l.y * h, w * 0.0028, h * 0.0018),
        Paint()..color = c.withOpacity(a),
      );
    }

    // 5. bokeh
    for (final b in bokeh) {
      final by = (b.y + 0.03 * math.sin(t * _tau + b.phase)) * h;
      final bx = b.x * w;
      final r = b.r * w;
      final c = b.color == 1 ? QColors.coral : Colors.white;
      final paint = Paint()
        ..shader = RadialGradient(colors: [
          c.withOpacity(b.alpha),
          c.withOpacity(0),
        ]).createShader(Rect.fromCircle(center: Offset(bx, by), radius: r));
      canvas.drawCircle(Offset(bx, by), r, paint);
    }

    // 6. particle network (Q-bit motif) in the upper field
    final pts = <Offset>[];
    for (final n in nodes) {
      final x = (n.bx + n.ampx * math.sin(t * _tau + n.phase));
      final y = (n.by + n.ampy * math.cos(t * _tau + n.phase));
      pts.add(Offset(x * w, y * h));
    }
    final linePaint = Paint()..strokeWidth = 1;
    final thresh = w * 0.19;
    for (var i = 0; i < pts.length; i++) {
      for (var j = i + 1; j < pts.length; j++) {
        final d = (pts[i] - pts[j]).distance;
        if (d < thresh) {
          linePaint.color = QColors.coral.withOpacity(0.10 * (1 - d / thresh));
          canvas.drawLine(pts[i], pts[j], linePaint);
        }
      }
    }
    final dotPaint = Paint()..color = const Color(0xFFFF785A).withOpacity(0.5);
    for (final p in pts) {
      canvas.drawCircle(p, w * 0.004, dotPaint);
    }

    // 7. focus scrim for gameplay
    if (dim) {
      final scrim = Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF07070A).withOpacity(0.30),
            const Color(0xFF07070A).withOpacity(0.82),
          ],
          stops: const [0, 0.95],
          radius: 1.1,
        ).createShader(Rect.fromCircle(
            center: Offset(w * 0.5, h * 0.4), radius: w));
      canvas.drawRect(rect, scrim);
    }

    // 8. vignette bands (legibility)
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h * 0.30),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF07070A).withOpacity(0.9),
            const Color(0xFF07070A).withOpacity(0.15)
          ],
        ).createShader(Rect.fromLTWH(0, 0, w, h * 0.30)),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, h * 0.60, w, h * 0.40),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            const Color(0xFF07070A).withOpacity(0.96),
            const Color(0xFF07070A).withOpacity(0.15)
          ],
        ).createShader(Rect.fromLTWH(0, h * 0.60, w, h * 0.40)),
    );
  }

  @override
  bool shouldRepaint(covariant _BgPainter old) => true;
}
