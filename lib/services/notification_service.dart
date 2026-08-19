import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/progress_store.dart';
import '../models/word.dart';

/// Schedules the daily "word from your collection" reminder — a notification
/// whose title IS an actual word the learner is working on (due for review, or
/// in their learning pile), so the reminder itself teaches. Mobile only:
/// flutter_local_notifications has no web/desktop backend, so every method is a
/// safe no-op off Android/iOS.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> init() async {
    if (!supported || _ready) return;
    tzdata.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation(await FlutterTimezone.getLocalTimezone()));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('UTC'));
    }
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
      // Tapping a reminder just opens the app for now; a deep-link into a
      // one-word review can hang off this payload later.
      onDidReceiveNotificationResponse: (_) {},
    );
    _ready = true;
  }

  /// Ask the OS for permission (iOS prompt / Android 13+ runtime permission).
  Future<bool> requestPermission() async {
    if (!supported) return false;
    await init();
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final ok = await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      return ok ?? false;
    }
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final ok = await android?.requestNotificationsPermission();
    return ok ?? false;
  }

  /// Cancel and re-schedule the next [days] daily reminders, each showing a
  /// concrete word from the user's collection. Call on enable, on app open, and
  /// after a match so the picks stay fresh.
  Future<void> rescheduleDailyWords({
    required List<Word> allWords,
    required ProgressStore store,
    required String locale,
    int hour = 9,
    int minute = 0,
    int days = 7,
  }) async {
    if (!supported) return;
    await init();
    await _plugin.cancelAll();
    if (allWords.isEmpty) return;

    final picks = _pickCollectionWords(allWords, store, days);
    if (picks.isEmpty) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final dueBadge = store.dueCount(nowMs).clamp(0, 99);
    final base = _firstFire(hour, minute);

    for (var i = 0; i < picks.length; i++) {
      final w = picks[i];
      final meaning = w.glossFor(locale).correct;
      // Rebuilt at the target wall-clock time on each day rather than
      // `base.add(Duration(days: i))`, which adds 24 absolute hours and so
      // drifts the reminder by an hour either side of a DST change — a 9am
      // reminder quietly becoming an 8am or 10am one for a week.
      final when = _fireOn(base, i, hour, minute);
      final androidDetails = AndroidNotificationDetails(
        'qbit_daily',
        'Daily word reminders',
        channelDescription: 'A word from your collection, every day',
        importance: Importance.high,
        priority: Priority.high,
        ticker: w.word,
      );
      final iosDetails = DarwinNotificationDetails(
        // The unlocked app-icon badge reflects how many words are due.
        badgeNumber: dueBadge == 0 ? null : dueBadge,
      );
      await _plugin.zonedSchedule(
        1000 + i,
        w.word, // title = the actual word
        meaning, // body = its meaning
        when,
        NotificationDetails(android: androidDetails, iOS: iosDetails),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: w.id,
      );
    }
  }

  Future<void> cancelAll() async {
    if (!supported) return;
    await init();
    await _plugin.cancelAll();
  }

  /// Order: words due for review first, then the rest of the learning pile,
  /// then fresh words to keep the queue full — i.e. the user's collection first.
  List<Word> _pickCollectionWords(
      List<Word> all, ProgressStore store, int count) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final due = <Word>[];
    final learning = <Word>[];
    final fresh = <Word>[];
    for (final w in all) {
      final p = store.progressFor(w.id);
      if (p.seen > 0 && p.dueAtMillis <= now) {
        due.add(w);
      } else if (p.seen > 0) {
        learning.add(w);
      } else {
        fresh.add(w);
      }
    }
    due.sort((a, b) => store
        .progressFor(a.id)
        .dueAtMillis
        .compareTo(store.progressFor(b.id).dueAtMillis));
    fresh.sort((a, b) => a.freqRank.compareTo(b.freqRank));

    final out = <Word>[];
    final seen = <String>{};
    for (final w in [...due, ...learning, ...fresh]) {
      if (seen.add(w.id)) out.add(w);
      if (out.length >= count) break;
    }
    return out;
  }

  /// [base] shifted by [days] CALENDAR days, keeping the same wall-clock time.
  tz.TZDateTime _fireOn(tz.TZDateTime base, int days, int hour, int minute) =>
      tz.TZDateTime(
          tz.local, base.year, base.month, base.day + days, hour, minute);

  tz.TZDateTime _firstFire(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var d = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (!d.isAfter(now)) d = d.add(const Duration(days: 1));
    return d;
  }
}
