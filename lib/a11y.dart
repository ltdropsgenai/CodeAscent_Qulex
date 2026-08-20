import 'package:flutter/material.dart';

/// Accessibility helpers, in one place so there is exactly one answer to
/// "does this app respect that setting?"
///
/// WHY THIS FILE EXISTS. An audit of the build on 20 Aug 2026 found five total
/// references to `disableAnimations`, `textScalerOf` and `Semantics(` across
/// the entire app — one of them in a test. That is not a small gap; it is the
/// difference between an app a VoiceOver user can play and one they cannot,
/// and it is the kind of thing an App Store reviewer finds in ninety seconds
/// with the accessibility inspector.
///
/// The rule from here on: nothing reads MediaQuery for an accessibility flag
/// directly. It asks here, so the behaviour is consistent, testable, and
/// possible to find.
class A11y {
  const A11y._();

  /// True when the OS has been asked to reduce motion.
  ///
  /// Covers iOS "Reduce Motion", Android "Remove animations", and the
  /// equivalent desktop settings — Flutter folds all of them into this one
  /// flag. Every animation in Qulex that runs on its own (rather than in
  /// response to a tap) must check this: the drifting vocabulary field, the
  /// Ken Burns backdrop, the title sequence, the handoff beat.
  static bool reduceMotion(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  /// A duration that collapses to nothing under reduce-motion.
  ///
  /// Zero rather than "fast": someone who asked for less motion wants the end
  /// state, not a quicker version of the journey to it.
  static Duration duration(BuildContext context, Duration d) =>
      reduceMotion(context) ? Duration.zero : d;

  /// The largest text scale the app's fixed-metric chrome is built to survive.
  ///
  /// Flutter does not clamp by default, and iOS's accessibility sizes go past
  /// 3x — at which point a 13pt button label is 39pt and no amount of flexible
  /// layout saves a segmented control with three cells in it.
  ///
  /// 2.0 is a deliberate compromise, not a shrug. It covers every non-
  /// accessibility Dynamic Type size and the first two accessibility sizes,
  /// which is where the overwhelming majority of users who change the setting
  /// actually sit; and because the ceiling is honest, the widgets below it are
  /// built to genuinely grow rather than to clip. Everything in ui.dart scales
  /// its BOX with its text — see [scale].
  static const double maxTextScale = 2.0;

  /// The scale factor Qulex will actually honour, clamped to [maxTextScale].
  static double textScale(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(100) / 100;

  /// Scales a fixed pixel metric by the user's text size.
  ///
  /// Any hard-coded height, width or icon size that sits NEXT TO text has to
  /// grow with it, or large type spills out of a box that stayed the same size.
  /// This is the one-liner that makes a 42pt segmented cell become a 63pt one.
  static double scale(BuildContext context, double px) =>
      px * textScale(context).clamp(1.0, maxTextScale);

  /// Wraps the app so the OS text size is honoured up to [maxTextScale].
  ///
  /// Applied once, at the root, in main.dart.
  static Widget clampTextScale(BuildContext context, Widget child) {
    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(
        textScaler: mq.textScaler.clamp(maxScaleFactor: maxTextScale),
      ),
      child: child,
    );
  }
}
