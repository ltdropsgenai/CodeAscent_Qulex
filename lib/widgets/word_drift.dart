import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme.dart';

/// A slow field of vocabulary words drifting behind the Qulex mark.
///
/// This is the "video" beat from the storyboard, rendered live instead of
/// shipped as a file: no bundle cost, no decoder, no first-frame stall, and
/// it adapts to whatever size the display actually is. One [Ticker] drives
/// one [CustomPainter] — the words are painted, not widgets, so two dozen of
/// them cost one repaint of one layer rather than a rebuild of two dozen
/// subtrees.
///
/// Rotation works two ways, both deliberate:
///   * across launches — the deck is shuffled from a launch-varying seed and
///     entered at a rotating offset, so you don't meet the same six words
///     every time you open the app;
///   * within a single play — when a token finishes fading out it adopts the
///     *next* word off the deck rather than repeating its own, so the field
///     keeps turning over for as long as the intro is on screen.
///
/// Honours the OS "reduce motion" setting: the field is composed once and
/// held still rather than drifting.
class WordDrift extends StatefulWidget {
  /// Words to cycle through. Falls back to [kDriftWords] when empty or too
  /// thin, so this works before (or entirely without) the catalogue loading.
  final List<String> words;

  /// 0 → invisible, 1 → full strength. Animate this to bring the field up
  /// under the mark and take it back out on exit.
  final double strength;

  /// Fraction of the height kept clear down the middle for the wordmark.
  /// Tokens dissolve as they approach it instead of drifting through it.
  final double clearCenter;

  /// Fixes the deck order and token layout. Leave null in the app — the whole
  /// point is that the field differs every launch — and set it in tests, where
  /// a capture that changes on every run cannot be compared against anything.
  final int? seed;

  const WordDrift({
    super.key,
    this.words = const [],
    this.strength = 1.0,
    this.clearCenter = 0.30,
    this.seed,
  });

  @override
  State<WordDrift> createState() => _WordDriftState();
}

/// A hand-picked deck: words that set well in a serif and that say something
/// about the library's range. Used when no catalogue words are supplied.
const List<String> kDriftWords = <String>[
  'perspicacious', 'ephemeral', 'quixotic', 'salient', 'obdurate',
  'lucid', 'halcyon', 'sonorous', 'intrepid', 'nascent',
  'eloquent', 'sanguine', 'tenacity', 'verdant', 'zenith',
  'candour', 'august', 'reticent', 'limpid', 'arcane',
  'cogent', 'redolent', 'stoic', 'vestige', 'wry',
  'prescient', 'laconic', 'fastidious', 'ineffable', 'susurrus',
];

class _DriftToken {
  String word = '';
  double x = 0; // 0..1 of width
  double y = 0; // 0..1 of height, at birth
  double drift = 0; // fraction of height travelled over a full life
  double life = 0; // 0..1
  double rate = 0; // life per second
  double size = 0; // logical px
  double weight = 0; // peak opacity
  bool accent = false; // coral instead of cream

  // Cached glyph layout. Re-laid-out only when the word, size, colour or
  // quantized alpha actually changes — see _alphaStep.
  TextPainter? tp;
  String _kWord = '';
  double _kSize = -1;
  bool _kAccent = false;
  int _kAlpha = -1;
}

class _WordDriftState extends State<WordDrift>
    with SingleTickerProviderStateMixin {
  static const int _tokenCount = 18;

  late final Ticker _ticker;
  late final math.Random _r;

  /// Bumped once per frame. The painter listens to this, so a drifting field
  /// repaints without rebuilding any widget.
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);

  final List<_DriftToken> _tokens = [];
  List<String> _deck = const [];
  int _cursor = 0;
  bool _reduceMotion = false;
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    // Launch-varying by default: a different slice of the deck, in a
    // different order, every time the app opens. A caller can pin it (tests).
    _r = math.Random(
        widget.seed ?? (DateTime.now().microsecondsSinceEpoch & 0x7fffffff));
    _rebuildDeck();
    for (var i = 0; i < _tokenCount; i++) {
      final t = _DriftToken();
      _reseed(t);
      // Stagger the initial phases so the field is already populated on the
      // first frame instead of every word fading up in unison.
      t.life = i / _tokenCount;
      _tokens.add(t);
    }
    _ticker = createTicker(_tick)..start();
    PaintingBinding.instance.systemFonts.addListener(_onFontsChanged);
  }

  /// Glyph layouts are cached per (word, size, colour, alpha step), and on a
  /// cold start that cache can be filled before the brand font has finished
  /// loading — google_fonts resolves asynchronously. A token sitting in the
  /// steady part of its life has a constant alpha, so nothing would ever
  /// invalidate its entry and it would keep painting fallback glyphs for the
  /// whole intro while its neighbours re-shaped correctly. Dropping the cache
  /// when the font set changes is what stops that.
  void _onFontsChanged() {
    for (final t in _tokens) {
      t.tp?.dispose();
      t.tp = null;
    }
    _frame.value++;
  }

  @override
  void didUpdateWidget(covariant WordDrift old) {
    super.didUpdateWidget(old);
    if (!identical(old.words, widget.words)) _rebuildDeck();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final rm = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (rm == _reduceMotion) return;
    _reduceMotion = rm;
    if (_reduceMotion) {
      // Compose one still frame at a pleasant spread of lives and hold it.
      for (var i = 0; i < _tokens.length; i++) {
        _tokens[i].life = 0.30 + 0.34 * (i / _tokens.length);
      }
      _frame.value++;
    }
  }

  void _rebuildDeck() {
    final src = widget.words.isNotEmpty ? widget.words : kDriftWords;
    // Only words that read at a glance: single token, no hyphen, short enough
    // to sit inside a phone's width at display size.
    final usable = <String>[];
    final seen = <String>{};
    for (final w in src) {
      final s = w.trim();
      if (s.isEmpty || s.length > 13) continue;
      if (s.contains(' ') || s.contains('-')) continue;
      if (!seen.add(s.toLowerCase())) continue;
      usable.add(s);
    }
    _deck = (usable.length >= 8 ? usable : List<String>.from(kDriftWords))
      ..shuffle(_r);
    _cursor = _deck.isEmpty ? 0 : _r.nextInt(_deck.length);
  }

  String _nextWord() {
    if (_deck.isEmpty) return '';
    final w = _deck[_cursor % _deck.length];
    _cursor++;
    return w;
  }

  /// Roughly how much of the width a token covers, for collision purposes.
  /// Cheaper and steadier than measuring: the exact glyph width doesn't matter
  /// when all we want is "don't put these two on top of each other".
  static double _span(_DriftToken t) => t.word.length * t.size * 0.00075 + 0.10;

  /// True if placing [t] at (x, y) would sit on top of a token already live.
  bool _collides(_DriftToken t, double x, double y) {
    for (final o in _tokens) {
      if (identical(o, t) || o.word.isEmpty) continue;
      final oy = o.y + o.drift * o.life;
      if ((y - oy).abs() > 0.042) continue;
      if ((x - o.x).abs() < (_span(t) + _span(o)) / 2) return true;
    }
    return false;
  }

  void _reseed(_DriftToken t) {
    t.word = _nextWord();
    // Size first: _span() reads it to decide how much room this token needs,
    // so choosing a position before setting it would size the collision test
    // off the token's PREVIOUS life (or off zero, the first time round).
    t.size = 12.0 + _r.nextDouble() * 13.0;
    // A few attempts at a spot that isn't already occupied. Purely random
    // placement puts two words on top of each other often enough to notice —
    // and an overlap reads as a rendering fault rather than as depth. Give up
    // after eight tries and take the last one: a slightly crowded frame is
    // better than a stalled loop, and the token fades anyway.
    var x = 0.06 + _r.nextDouble() * 0.88;
    var top = _r.nextBool();
    var y = top ? _r.nextDouble() * 0.40 : 0.60 + _r.nextDouble() * 0.40;
    for (var attempt = 0; attempt < 8 && _collides(t, x, y); attempt++) {
      x = 0.06 + _r.nextDouble() * 0.88;
      top = _r.nextBool();
      y = top ? _r.nextDouble() * 0.40 : 0.60 + _r.nextDouble() * 0.40;
    }
    t.x = x;
    // The middle belongs to the wordmark; a token seeded there just dissolves
    // again immediately, which is why births are biased to top and bottom.
    t.y = y;
    t.drift = (0.05 + _r.nextDouble() * 0.10) * (top ? -1 : 1);
    t.rate = 1 / (7.0 + _r.nextDouble() * 9.0); // a full life in 7–16s
    // Peak opacity is kept low on purpose: this is a texture behind the
    // mark, not a second thing to read. Anything above ~0.3 stops reading
    // as depth and starts competing with the wordmark.
    t.weight = 0.09 + _r.nextDouble() * 0.19;
    t.accent = _r.nextInt(7) == 0; // roughly one in seven takes the coral
    t.life = 0;
  }

  void _tick(Duration elapsed) {
    if (_reduceMotion) return;
    var dt = (elapsed - _last).inMicroseconds / Duration.microsecondsPerSecond;
    _last = elapsed;
    // Guard the first frame and any resume-from-background jump: a large dt
    // would teleport the whole field instead of drifting it.
    if (dt <= 0 || dt > 0.25) dt = 1 / 60;
    for (final t in _tokens) {
      t.life += t.rate * dt;
      if (t.life >= 1.0) _reseed(t); // adopt the NEXT word off the deck
    }
    _frame.value++;
  }

  @override
  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(_onFontsChanged);
    _ticker.dispose();
    _frame.dispose();
    for (final t in _tokens) {
      t.tp?.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _DriftPainter(
            tokens: _tokens,
            strength: widget.strength.clamp(0.0, 1.0),
            clearCenter: widget.clearCenter,
            repaint: _frame,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _DriftPainter extends CustomPainter {
  final List<_DriftToken> tokens;
  final double strength;
  final double clearCenter;

  _DriftPainter({
    required this.tokens,
    required this.strength,
    required this.clearCenter,
    required Listenable repaint,
  }) : super(repaint: repaint);

  /// Fade envelope over a token's life: in, hold, out.
  static double _envelope(double life) {
    if (life < 0.18) return life / 0.18;
    if (life > 0.74) return (1 - life) / 0.26;
    return 1.0;
  }

  /// Opacity is baked into the glyph colour rather than applied with a
  /// saveLayer — a layer per token per frame is the expensive way to do this.
  /// Quantizing to 24 steps means a token re-shapes about twenty times over
  /// its 7–16 second life instead of sixty times a second.
  static int _alphaStep(double a) => (a * 24).round().clamp(0, 24);

  @override
  void paint(Canvas canvas, Size size) {
    if (strength <= 0.004 || size.isEmpty) return;
    final half = clearCenter / 2;

    for (final t in tokens) {
      if (t.word.isEmpty) continue;
      final env = _envelope(t.life).clamp(0.0, 1.0);
      if (env <= 0.01) continue;

      final y = t.y + t.drift * t.life;
      if (y < -0.12 || y > 1.12) continue;

      // Clear a band down the middle so nothing drifts across the wordmark —
      // words dissolve as they approach it rather than being hard-clipped,
      // which reads as depth instead of a hole cut in the layer.
      final d = (y - 0.5).abs();
      final clear = d <= half ? 0.0 : ((d - half) / 0.14).clamp(0.0, 1.0);
      if (clear <= 0.01) continue;

      // Fade out at the very top and bottom so nothing collides with the
      // status bar or the skip hint pinned to the bottom of the screen.
      final edge = ((y - 0.06) / 0.07).clamp(0.0, 1.0) *
          ((0.90 - y) / 0.06).clamp(0.0, 1.0);
      if (edge <= 0.01) continue;

      final step = _alphaStep(t.weight * env * clear * edge * strength);
      if (step == 0) continue;
      final alpha = step / 24;

      if (t.tp == null ||
          t._kWord != t.word ||
          t._kSize != t.size ||
          t._kAccent != t.accent ||
          t._kAlpha != step) {
        t.tp?.dispose();
        t.tp = TextPainter(
          text: TextSpan(
            text: t.word,
            style: QType.serif(
              size: t.size,
              color: (t.accent ? QColors.coral : QColors.cream)
                  .withOpacity(alpha),
              weight: FontWeight.w400,
              style: FontStyle.italic,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        t._kWord = t.word;
        t._kSize = t.size;
        t._kAccent = t.accent;
        t._kAlpha = step;
      }
      final tp = t.tp!;

      final maxX = math.max(6.0, size.width - tp.width - 6.0);
      final dx = (t.x * size.width - tp.width / 2).clamp(6.0, maxX);
      final dy = y * size.height - tp.height / 2;
      tp.paint(canvas, Offset(dx, dy));
    }
  }

  // The tokens mutate in place, so the painter can never decide from its own
  // fields whether anything moved. Repaints are gated by the frame notifier
  // passed as `repaint`, which only fires while the ticker is running.
  @override
  bool shouldRepaint(covariant _DriftPainter old) => true;
}
