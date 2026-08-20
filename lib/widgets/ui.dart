import 'package:flutter/material.dart';
import '../a11y.dart';
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
        child: Semantics(
          // These are the only structural signposts on a long settings page.
          // Marked as headers so VoiceOver's rotor can jump between sections
          // instead of forcing a swipe through every row.
          header: true,
          child: Text(text.toUpperCase(),
              style:
                  QType.mono(size: 12.5, color: QColors.muted, spacing: 2.2)),
        ),
      );
}

/// A 1px hairline divider.
class QRule extends StatelessWidget {
  final double indent;
  const QRule({super.key, this.indent = 0});
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: Container(
          margin: EdgeInsets.only(left: indent),
          height: 1,
          color: QColors.rule,
        ),
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

  /// Above this text scale the row stops being a row.
  ///
  /// A trailing control has a minimum width that does not shrink — the stepper
  /// is two 44pt buttons around a number — so as the type grows, the title's
  /// share of a 390pt phone collapses. At 2x it collapsed to about 30pt and
  /// "New words per day" rendered one character per line, straight down the
  /// screen. Below the threshold the row reads better side by side; above it,
  /// stacking is the only layout that fits. iOS does the same thing to its own
  /// list rows at the larger Dynamic Type sizes.
  static const double _stackAboveScale = 1.35;

  @override
  Widget build(BuildContext context) {
    final stacked = A11y.textScale(context) >= _stackAboveScale;

    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: QType.serif(size: 18, color: QColors.cream, height: 1.2)),
        if (sub != null) ...[
          const SizedBox(height: 5),
          // Sans, not mono. Space Mono is a wide face with a small x-height:
          // once these lines were big enough to read, they were also wide
          // enough to wrap three times beside a stepper. Mono stays where it
          // belongs — short uppercase labels and buttons. These are sentences.
          Text(sub!,
              style: QType.sans(size: 13, color: QColors.muted, height: 1.4)),
        ],
      ],
    );

    final leading = icon == null
        ? null
        // Purely decorative: the title beside it already says what this row is,
        // so announcing the icon would make every row start with noise.
        : ExcludeSemantics(
            child: Icon(icon,
                size: A11y.scale(context, 20), color: QColors.coral));

    final trail = trailing ??
        (onTap != null
            ? ExcludeSemantics(
                child: Icon(Icons.chevron_right,
                    size: A11y.scale(context, 22), color: QColors.dim))
            : null);

    Widget row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 15),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  if (leading != null) ...[
                    leading,
                    SizedBox(width: A11y.scale(context, 14)),
                  ],
                  Expanded(child: titleBlock),
                ]),
                if (trail != null) ...[
                  const SizedBox(height: 12),
                  // Left-aligned under the title rather than right-aligned in
                  // space: at this type size the eye is already tracking the
                  // left margin.
                  Align(alignment: Alignment.centerLeft, child: trail),
                ],
              ],
            )
          : Row(children: [
              if (leading != null) ...[
                leading,
                SizedBox(width: A11y.scale(context, 14)),
              ],
              Expanded(child: titleBlock),
              if (trail != null)
                Padding(padding: const EdgeInsets.only(left: 12), child: trail),
            ]),
    );

    if (onTap != null) {
      row = Semantics(
        button: true,
        // The title alone is the label; the subtitle becomes the hint, which is
        // how a screen reader distinguishes "what is this" from "what will
        // happen". Merging descendants stops the row being read as three
        // separate unrelated fragments.
        label: title,
        hint: sub,
        child: MergeSemantics(child: InkWell(onTap: onTap, child: row)),
      );
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

  /// What the toggle controls, for a screen reader. The row beside it usually
  /// supplies this via MergeSemantics, but a bare toggle needs its own.
  final String? semanticLabel;

  const QToggle(
      {super.key,
      required this.value,
      required this.onChanged,
      this.semanticLabel});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      // `toggled` is what makes VoiceOver say "on"/"off" and offer the right
      // gesture, rather than reading an unlabelled tap target.
      toggled: value,
      label: semanticLabel,
      onTap: () => onChanged(!value),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: AnimatedContainer(
          duration: A11y.duration(context, const Duration(milliseconds: 160)),
          width: A11y.scale(context, 46),
          height: A11y.scale(context, 26),
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: value ? QColors.coral.withOpacity(0.16) : Colors.transparent,
            border: Border.all(
                color: value ? QColors.coral : QColors.rule, width: 1),
            borderRadius: BorderRadius.circular(kQRadius),
          ),
          child: AnimatedAlign(
            duration: A11y.duration(context, const Duration(milliseconds: 160)),
            curve: Curves.easeOut,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: A11y.scale(context, 16),
              height: A11y.scale(context, 18),
              decoration: BoxDecoration(
                color: value ? QColors.coral : QColors.muted,
                borderRadius: BorderRadius.circular(kQRadius),
              ),
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

  /// What is being stepped, e.g. "New words per day". Without it a screen
  /// reader announces two unlabelled buttons around a bare number.
  final String? semanticLabel;

  const QStepper({
    super.key,
    required this.value,
    required this.onMinus,
    required this.onPlus,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    // Three nodes, each of which says what it is: the value announces
    // "New words per day, 20", and the two buttons name what they change.
    //
    // The tempting alternative is ONE node with `slider: true` plus increase
    // and decrease actions, which is the swipe-up/swipe-down gesture VoiceOver
    // users expect from a stepper. Flutter asserts that such a node also
    // supplies increasedValue and decreasedValue, and this widget takes an
    // opaque Object rather than a number, so it cannot compute either. Labelled
    // buttons are less elegant and actually work. (The assert is not
    // theoretical — it fired in adaptive_frames_test.dart on the first try.)
    final label = semanticLabel;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _btn(context, Icons.remove, onMinus,
          label == null ? null : 'Decrease $label'),
      Semantics(
        label: label,
        value: '$value',
        readOnly: true,
        child: ExcludeSemantics(
          child: Container(
            width: A11y.scale(context, 46),
            alignment: Alignment.center,
            child: Text('$value',
                style: QType.serif(size: 22, color: QColors.coral)),
          ),
        ),
      ),
      _btn(context, Icons.add, onPlus,
          label == null ? null : 'Increase $label'),
    ]);
  }

  Widget _btn(BuildContext context, IconData i, VoidCallback onTap,
      String? label) {
    // Grows with the text size beside it, and never smaller than the 44pt
    // minimum touch target both platforms ask for. The old fixed 34 was under
    // it on every device.
    final side = A11y.scale(context, 44);
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: side,
          height: side,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: QColors.rule, width: 1),
            borderRadius: BorderRadius.circular(kQRadius),
          ),
          child: Icon(i, size: A11y.scale(context, 18), color: QColors.muted),
        ),
      ),
    );
  }
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

  /// Above this text scale the control stops being horizontal.
  ///
  /// Three cells across a 390pt phone gives each about 128pt. At 2x, "RELAXED"
  /// in tracked-out mono needs more than that, so it wrapped mid-word:
  /// "RELAX / ED", "NORMA / L". There is no amount of shrinking that fixes
  /// three long words on a narrow phone — the layout has to change. Stacked,
  /// each option gets the full width and the selected one is marked by a bar on
  /// the leading edge instead of an underline.
  static const double _stackAboveScale = 1.35;

  @override
  Widget build(BuildContext context) {
    final stacked = A11y.textScale(context) >= _stackAboveScale;

    Widget cell(int i, {required bool vertical}) {
      final active = i == index;
      return Semantics(
        // A segmented control is a radio group. Saying so is what makes a
        // screen reader announce "Normal, selected, 2 of 3" instead of reading
        // three loose words with no indication which is active — which matters
        // more here than anywhere else in the app, because selection is
        // signalled by colour alone.
        inMutuallyExclusiveGroup: true,
        selected: active,
        button: true,
        label: labels[i],
        onTap: () => onChanged(i),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(i),
          // Deliberately NOT a Container with `alignment` set. A Container that
          // has an alignment and bounded constraints tries to be as big as
          // possible, and the fixed `height: 42` this replaced was the only
          // thing holding that back — swap it for a minHeight and the control
          // silently grows to fill its parent. It did, immediately; see
          // adaptive_frames_test.dart.
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: A11y.scale(context, 42)),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: vertical
                    ? Border(
                        left: BorderSide(
                            color: active ? QColors.coral : Colors.transparent,
                            width: 2))
                    : Border(
                        bottom: BorderSide(
                            color: active ? QColors.coral : Colors.transparent,
                            width: 2)),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: vertical ? 14 : 4, vertical: 10),
                child: Align(
                  alignment:
                      vertical ? Alignment.centerLeft : Alignment.center,
                  heightFactor: 1,
                  child: Text(labels[i].toUpperCase(),
                      textAlign: vertical ? TextAlign.left : TextAlign.center,
                      style: QType.mono(
                          size: 12,
                          spacing: 1,
                          color: active ? QColors.coral : QColors.muted)),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: QColors.rule, width: 1),
        borderRadius: BorderRadius.circular(kQRadius),
      ),
      child: stacked
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < labels.length; i++) ...[
                  if (i > 0) const QRule(),
                  cell(i, vertical: true),
                ],
              ],
            )
          : Row(children: [
              for (var i = 0; i < labels.length; i++) ...[
                if (i > 0)
                  ExcludeSemantics(
                    child: Container(
                        width: 1,
                        height: A11y.scale(context, 40),
                        color: QColors.rule),
                  ),
                Expanded(child: cell(i, vertical: false)),
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
            ExcludeSemantics(
                child: Icon(icon, size: A11y.scale(context, 15), color: fg)),
            SizedBox(width: A11y.scale(context, 8)),
          ],
          Flexible(
            child: Text(label.toUpperCase(),
                textAlign: TextAlign.center,
                style: QType.mono(size: 13, spacing: 1.3, color: fg)),
          ),
        ],
      ),
    );
    return Semantics(
      button: true,
      // Announced in sentence case, not the SHOUTING the button is set in —
      // VoiceOver reads all-caps text letter by letter on some voices.
      label: label,
      enabled: enabled,
      onTap: onTap,
      child: ExcludeSemantics(
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: GestureDetector(
              behavior: HitTestBehavior.opaque, onTap: onTap, child: child),
        ),
      ),
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
