import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import '../data/progress_store.dart';
import '../models/word.dart';

/// Pushes a "word of the moment" — drawn from the learner's own collection —
/// to the native home/lock-screen widget. Mobile only; a no-op elsewhere.
///
/// Android works out of the box once the AppWidgetProvider is registered.
/// iOS needs a WidgetKit extension + shared App Group (see the setup notes in
/// the repo); [appGroupId] is set at startup so the shared store lines up.
class WidgetService {
  WidgetService._();
  static final WidgetService instance = WidgetService._();

  static const appGroupId = 'group.com.codeascent.qbit';

  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> init() async {
    if (!_supported) return;
    try {
      await HomeWidget.setAppGroupId(appGroupId);
    } catch (_) {/* Android ignores this; iOS needs the group configured */}
  }

  /// Refresh the widget with a word from the user's due/learning pile.
  Future<void> update({
    required List<Word> words,
    required ProgressStore store,
    required String locale,
  }) async {
    if (!_supported || words.isEmpty) return;
    final w = _pick(words, store);
    if (w == null) return;
    try {
      await HomeWidget.saveWidgetData<String>('word', w.word);
      await HomeWidget.saveWidgetData<String>(
          'meaning', w.glossFor(locale).correct);
      await HomeWidget.updateWidget(
        androidName: 'QbitWidgetProvider',
        iOSName: 'QbitWidget',
      );
    } catch (_) {/* best-effort */}
  }

  Word? _pick(List<Word> all, ProgressStore store) {
    final now = DateTime.now().millisecondsSinceEpoch;
    Word? due, learning, fresh;
    for (final w in all) {
      final p = store.progressFor(w.id);
      if (p.suspended) continue;
      if (p.seen > 0 && p.dueAtMillis <= now) {
        due ??= w;
      } else if (p.seen > 0) {
        learning ??= w;
      } else {
        fresh ??= w;
      }
      if (due != null) break; // a due word is the best pick; stop early
    }
    return due ?? learning ?? fresh ?? all.first;
  }
}
