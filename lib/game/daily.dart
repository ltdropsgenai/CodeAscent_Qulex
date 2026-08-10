import 'dart:math' as math;
import '../models/word.dart';

/// A deterministic set of words for a given date — everyone gets the same
/// Daily Challenge on the same day, and it's stable across the day.
List<Word> dailyDeck(List<Word> all, DateTime date, {int count = 10}) {
  if (all.isEmpty) return const [];
  final seed = date.year * 10000 + date.month * 100 + date.day;
  final idx = List<int>.generate(all.length, (i) => i);
  final r = math.Random(seed);
  for (var i = idx.length - 1; i > 0; i--) {
    final j = r.nextInt(i + 1);
    final t = idx[i];
    idx[i] = idx[j];
    idx[j] = t;
  }
  return idx.take(count).map((i) => all[i]).toList();
}

/// 'YYYY-MM-DD' local date key.
String ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
