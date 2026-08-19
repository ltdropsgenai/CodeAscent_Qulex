import 'package:flutter/material.dart';
import '../theme.dart';

/// Qulex editorial UI kit.
/// ---------------------------------------------------------------------------
/// Structure comes from hairline rules and type, never from rounded filled
/// boxes. Corners are squared (a 2px hint at most), coral touches only the one
/// active element, and everything is designed to sit over the photographic
/// backdrop. No Material pills, capsules, or Switch widgets.

const double kQRadius = 2.0; // near-square; the only curvature in the system

/// Uppercase Space Mono section signpost.
class QLabel extends StatelessWidget {
  final String text;
  final EdgeInsetsGeometry padding;
  const QLabel(this.text,
      {super.key, this.padding = const EdgeInsets.only(bottom: 14)});
  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Text(text.toUpperCase(),
            style: QType.mono(size: 12.5, color: QColors.muted, spacing: 2.2)),
      );
}

/// A 1px hairline divider.
class QRule extends StatelessWidget {
  final double indent;
  const QRule({super.key, this.indent = 0});
  @override
  Widget build(BuildContext context) => Container(
        margin: EdgeInsets.only(left: indent),
        height: 1,
        color: QColors.rule,
      );
}

/// An editorial list row: optional leading icon, serif title + mono sub, and a
/// trailing widget (or a chevron when tappable). A hairline sits beneath unless
/// [last]. This replaces the old per-item rounded outline cards.
class QRow extends StatelessWidget {
  final String title;
  final String? sub;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool last;
  const QRow({
    super.key,
    required this.title,
    this.sub,
    this.icon,
    this.trailing,
    this.onTap,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    Widget row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 15),
      child: Row(children: [
        if (icon != null) ...[
          Icon(icon, size: 20, color: QColors.coral),
          const SizedBox(width: 14),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: QType.serif(size: 18, color: QColors.cream, height: 1.2)),
              if (sub != null) ...[
                const SizedBox(height: 5),
                Text(sub!,
                    style: QType.mono(
                        size: 13, color: QColors.muted, spacing: 0.2)),
              ],
            ],
          ),
        ),
        if (trailing != null)
          Padding(padding: const EdgeInsets.only(left: 12), child: trailing!)
        else if (onTap != null)
          const Icon(Icons.chevron_right, size: 22, color: QColors.dim),
      ]),
    );
    if (onTap != null) {
      row = InkWell(onTap: onTap, child: row);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [row, if (!last) const QRule()],
    );
  }
}

/// A squared sliding toggle — replaces the Material Switch pill.
class QToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const QToggle({super.key, required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 46,
        height: 26,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: value ? QColors.coral.withOpacity(0.16) : Colors.transparent,
          border:
              Border.all(color: value ? QColors.coral : QColors.rule, width: 1),
          borderRadius: BorderRadius.circular(kQRadius),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 16,
            height: 18,
            decoration: BoxDecoration(
              color: value ? QColors.coral : QColors.muted,
              borderRadius: BorderRadius.circular(kQRadius),
            ),
          ),
        ),
      ),
    );
  }
}

/// Squared +/- stepper — replaces the circular icon buttons.
class QStepper extends StatelessWidget {
  final Object value;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  const QStepper(
      {super.key,
      required this.value,
      required this.onMinus,
      required this.onPlus});
  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _btn(Icons.remove, onMinus),
      Container(
        width: 46,
        alignment: Alignment.center,
        child: Text('$value',
            style: QType.serif(size: 22, color: QColors.coral)),
      ),
      _btn(Icons.add, onPlus),
    ]);
  }

  Widget _btn(IconData i, VoidCallback onTap) => InkWell(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: QColors.rule, width: 1),
            borderRadius: BorderRadius.circular(kQRadius),
          ),
          child: Icon(i, size: 18, color: QColors.muted),
        ),
      );
}

/// Hairline-divided segmented control; active cell = coral text + underline.
/// Replaces the pill segmented row.
class QSegment extends StatelessWidget {
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;
  const QSegment(
      {super.key,
      required this.labels,
      required this.index,
      required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: QColors.rule, width: 1),
        borderRadius: BorderRadius.circular(kQRadius),
      ),
      child: Row(children: [
        for (var i = 0; i < labels.length; i++) ...[
          if (i > 0) Container(width: 1, height: 40, color: QColors.rule),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(i),
              child: Container(
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                        color: i == index ? QColors.coral : Colors.transparent,
                        width: 2),
                  ),
                ),
                child: Text(labels[i].toUpperCase(),
                    style: QType.mono(
                        size: 12,
                        spacing: 1,
                        color: i == index ? QColors.coral : QColors.muted)),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

/// Squared button — coral fill (primary) or coral hairline (ghost). Mono caps.
/// Replaces every OutlinedButton / ElevatedButton / capsule.
class QButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final IconData? icon;
  final bool expand;
  const QButton(this.label,
      {super.key,
      this.onTap,
      this.primary = false,
      this.icon,
      this.expand = false});
  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = primary
        ? const Color(0xFF160603)
        : (enabled ? QColors.coral : QColors.dim);
    final child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: primary ? QColors.coral : Colors.transparent,
        border: Border.all(
            color: primary
                ? QColors.coral
                : (enabled ? QColors.coral : QColors.rule),
            width: 1),
        borderRadius: BorderRadius.circular(kQRadius),
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: fg),
            const SizedBox(width: 8),
          ],
          Text(label.toUpperCase(),
              style: QType.mono(size: 13, spacing: 1.3, color: fg)),
        ],
      ),
    );
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: GestureDetector(
          behavior: HitTestBehavior.opaque, onTap: onTap, child: child),
    );
  }
}

/// A headword set as large as it can be while still fitting on ONE line.
///
/// Long entries used to wrap mid-word — "osseointegration" broke after
/// "osseointegratio", leaving a single orphaned "n" on the second line under a
/// 46pt serif. There is no good place to break an unhyphenated word, so the
/// answer is not to break it: measure, and step the size down until it fits.
///
/// Multi-word headwords (the catalogue has a few — "grand jeté") are allowed
/// to wrap at a space rather than shrink to nothing, so the size floor is a
/// real floor: below it we let the phrase take a second line at the space.
class HeroWord extends StatelessWidget {
  final String text;
  final double maxSize;
  final double minSize;
  final Color color;
  final double height;

  const HeroWord(
    this.text, {
    super.key,
    this.maxSize = 46,
    this.minSize = 20,
    this.color = QColors.cream,
    this.height = 1.05,
  });

  /// The style [Text] will ACTUALLY render with.
  ///
  /// Text merges its `style` into the inherited DefaultTextStyle whenever
  /// `inherit` is true, which it is by default — and Material's default body
  /// style carries a `letterSpacing`. Measuring the bare QType.serif style
  /// therefore under-measures every headword by a few pixels per character,
  /// which is precisely enough to make a 20-character word that "fits" render
  /// with an ellipsis. Measure what will be drawn, not what was asked for.
  TextStyle _style(BuildContext context, double size) {
    final base = QType.serif(size: size, color: color, height: height);
    final inherited = DefaultTextStyle.of(context).style;
    return base.inherit ? inherited.merge(base) : base;
  }

  bool _fits(TextStyle style, double maxWidth, TextScaler scaler) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout(maxWidth: double.infinity);
    // A hair of slack: the paragraph builder and TextPainter can disagree by
    // a sub-pixel, and being one pixel optimistic here costs an ellipsis.
    return tp.width <= maxWidth - 0.5;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, cons) {
        final maxWidth = cons.maxWidth;
        if (!maxWidth.isFinite || maxWidth <= 0 || text.isEmpty) {
          return Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _style(context, maxSize));
        }
        // Honour the OS text-size setting in the measurement, or the word fits
        // here and overflows on a phone with larger type.
        final scaler = MediaQuery.textScalerOf(context);

        // A single token has no break opportunity, so it shrinks as far as it
        // needs to. A phrase does — "spike-timing-dependent plasticity" is a
        // real catalogue entry — so it stops shrinking well above the floor
        // and takes a second line at a space instead, which reads far better
        // than 20pt type.
        final hasBreak = text.contains(' ') || text.contains('-');
        final floor = hasBreak ? maxSize * 0.62 : minSize;

        var size = maxSize;
        if (!_fits(_style(context, maxSize), maxWidth, scaler)) {
          // Binary search for the largest whole point size that fits: about
          // five layouts of one short string, rather than stepping down one
          // point at a time.
          var lo = floor, hi = maxSize;
          while (hi - lo > 0.5) {
            final mid = (lo + hi) / 2;
            if (_fits(_style(context, mid), maxWidth, scaler)) {
              lo = mid;
            } else {
              hi = mid;
            }
          }
          size = lo;
        }

        final style = _style(context, size);
        final oneLine = _fits(style, maxWidth, scaler);
        return Text(
          text,
          maxLines: oneLine ? 1 : 2,
          softWrap: !oneLine,
          // Only reachable for a phrase that still overruns two lines; a single
          // token always has a size that fits, so it never ellipsises.
          overflow: TextOverflow.ellipsis,
          style: style,
        );
      },
    );
  }
}
