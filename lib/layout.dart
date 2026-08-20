import 'package:flutter/material.dart';

/// How much room we actually have, and what to do with it.
///
/// WHAT THIS REPLACES. Every screen used to be poured into one column whose
/// width came from a four-line function in main.dart that capped at 600pt.
/// That was defensible when the app was three screens long, but on an iPad it
/// produces exactly the thing reviewers complain about in this category: a
/// phone-shaped strip floating in the middle of a large display, with the
/// other 60% of the screen doing nothing. Qulex's own competitive board listed
/// it as an open gap, and it was.
///
/// THE MODEL. Three size classes, following the same breakpoints Material and
/// the iPad's own multitasking widths use, so the classes line up with real
/// device configurations rather than with numbers I liked:
///
///   compact   < 600   phone portrait, and an iPad Slide Over pane
///   medium    < 1000  phone landscape, iPad portrait, half-screen Split View
///   expanded  >=1000  iPad landscape, desktop, web
///
/// The rule is that CONTENT WIDTH and SHELL WIDTH are different questions.
/// Prose has an optimal measure of roughly 60-75 characters and gets no better
/// past it, so [readingWidth] stays tight no matter how big the display is —
/// stretching the About page to 1100pt would be worse, not better. What
/// changes with size is how many things sit SIDE BY SIDE, which is what
/// [isWide] gates.
enum QSizeClass { compact, medium, expanded }

class QLayout {
  const QLayout._();

  static QSizeClass classFor(double width) {
    if (width < 600) return QSizeClass.compact;
    if (width < 1000) return QSizeClass.medium;
    return QSizeClass.expanded;
  }

  static QSizeClass of(BuildContext context) =>
      classFor(MediaQuery.sizeOf(context).width);

  /// True when there is room to put two columns beside each other.
  ///
  /// Deliberately not just "expanded": an iPad in portrait is 834pt, which is
  /// medium, and is plainly wide enough for a two-pane home screen. What it is
  /// NOT wide enough for is two panes plus generous gutters, which is why the
  /// pane widths below are proportional.
  static bool isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 760;

  /// The comfortable measure for running text. Past this, lines get long
  /// enough that the eye loses its place returning to the left margin.
  static const double readingWidth = 620;

  /// Width of the app shell for a given display width.
  ///
  /// The old function capped at 600 for everything. This one lets a large
  /// display actually be large — the screens that know what to do with the
  /// room (Home, the game) spread into it, and the ones that do not (the
  /// prose pages) re-cap themselves to [readingWidth] internally, which is the
  /// right place for that decision to live.
  static double shellWidth(double available) {
    if (available < 600) return available; // phone: edge to edge, as before
    if (available < 1000) return available.clamp(0.0, 900.0);
    // Wide, but never wider than the display it has to fit inside — the
    // gutters and the column border are laid out from this number, and a
    // shell wider than the screen puts them off it.
    return available.clamp(0.0, 1180.0);
  }

  /// Horizontal padding that opens up as the display does.
  static EdgeInsets pagePadding(BuildContext context) {
    switch (of(context)) {
      case QSizeClass.compact:
        return const EdgeInsets.fromLTRB(24, 18, 24, 26);
      case QSizeClass.medium:
        return const EdgeInsets.fromLTRB(32, 22, 32, 32);
      case QSizeClass.expanded:
        return const EdgeInsets.fromLTRB(44, 28, 44, 40);
    }
  }
}

/// Centres [child] in a column no wider than [maxWidth].
///
/// Used by every screen whose content is prose or a single stack of controls.
/// Those screens do not become better by getting wider, and this is how they
/// say so — locally, rather than by forcing the whole app to stay narrow.
///
/// WHY NOT JUST `Center(child: ConstrainedBox(...))`. Because Center relaxes
/// the height constraint to loose, and the game screen's layout depends on a
/// TIGHT one: it has an Expanded inside a Column, and an IntrinsicHeight
/// wrapped around a subtree that contains a LayoutBuilder (HeroWord measures
/// itself). Loosen the height and IntrinsicHeight starts speculatively asking
/// that LayoutBuilder for an intrinsic dimension, which throws. Constraining
/// the WIDTH is the entire job here, so this passes the height through
/// untouched.
class ReadingColumn extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  const ReadingColumn(
      {super.key, required this.child, this.maxWidth = QLayout.readingWidth});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, cons) {
          if (cons.maxWidth <= maxWidth) return child; // nothing to do
          return Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: maxWidth,
              height: cons.hasBoundedHeight ? cons.maxHeight : null,
              child: child,
            ),
          );
        },
      );
}
