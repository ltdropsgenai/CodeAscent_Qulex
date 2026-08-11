import 'package:flutter/material.dart';
import '../theme.dart';

/// Qbit editorial UI kit.
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
            style: QType.mono(size: 11, color: QColors.muted, spacing: 2.5)),
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
          Icon(icon, size: 18, color: QColors.coral),
          const SizedBox(width: 14),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: QType.serif(size: 16.5, color: QColors.cream)),
              if (sub != null) ...[
                const SizedBox(height: 3),
                Text(sub!,
                    style: QType.mono(
                        size: 11.5, color: QColors.muted, spacing: 0.3)),
              ],
            ],
          ),
        ),
        if (trailing != null)
          Padding(padding: const EdgeInsets.only(left: 12), child: trailing!)
        else if (onTap != null)
          const Icon(Icons.chevron_right, size: 20, color: QColors.dim),
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
                        size: 10.5,
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
              style: QType.mono(size: 12, spacing: 1.5, color: fg)),
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
