import 'dart:math' as math;
import '../models/word.dart';

/// A deterministic set of words for a given date.
///
/// Everyone gets the same Daily Challenge on the same day — which only holds if
/// the caller passes the WHOLE catalogue. It used to be handed the learner's
/// level-filtered pool, so two learners at different levels got different
/// "shared" challenges, and finishing a placement mid-day silently changed
/// today's deck underneath you. Daily is the one thing in the app with a social
/// surface; it has to be the same deck for everybody or it means nothing.
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

/// The calendar day before [d].
///
/// Deliberately NOT `d.subtract(const Duration(days: 1))`. A Duration is 24
/// absolute hours, not "one day": on the morning after a spring-forward the
/// local clock has moved on an hour, so subtracting 24h lands an hour earlier
/// on the wall clock — and for anyone playing between 00:00 and 01:00, on the
/// day *before* yesterday. That made `registerPlay` fail to match
/// `lastPlayedYmd` and reset the streak to 1. Twice a year, in every
/// DST-observing market, for the app's main retention mechanic.
///
/// Built at noon rather than midnight because midnight is precisely the hour
/// that doesn't exist in the timezones that shift at 00:00 (Chile, Cuba,
/// Lord Howe). Noon always exists. Dart's DateTime constructor normalizes
/// out-of-range day values, so day 0 correctly becomes the last day of the
/// previous month.
DateTime previousDay(DateTime d) => DateTime(d.year, d.month, d.day - 1, 12);

/// [d] shifted by [days] calendar days. Same reasoning as [previousDay].
DateTime addDays(DateTime d, int days) =>
    DateTime(d.year, d.month, d.day + days, 12);
