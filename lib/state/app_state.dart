import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Global app settings: UI/native language + voice on/off. Persisted.
/// Used directly as `appState` (a singleton ChangeNotifier) so the base stays
/// free of a DI/provider dependency — widgets listen via AnimatedBuilder.
class AppState extends ChangeNotifier {
  static const _kLocale = 'qbit_locale';
  static const _kVoice = 'qbit_voice_on';
  static const _kPro = 'qbit_is_pro';
  static const _kReminders = 'qbit_reminders_on';
  static const _kReminderHour = 'qbit_reminder_hour';
  static const _kNewPerDay = 'qbit_new_per_day';
  static const _kIntensity = 'qbit_review_intensity';
  static const _kSeenIntro = 'qbit_seen_intro';

  String locale = 'en';
  bool voiceOn = true;

  /// Whether the player has been through the splash/intro screen. False on a
  /// brand-new install — that's when we show the differentiator pitch.
  bool seenIntro = false;

  /// Daily "word from your collection" reminders (mobile only).
  bool remindersOn = false;
  int reminderHour = 9; // local hour, 0–23

  /// Spaced-repetition dial.
  int newPerDay = 20; // new words introduced per day
  int reviewIntensity = 1; // 0 relaxed, 1 normal, 2 intense

  /// Interval multiplier for the chosen intensity (relaxed reviews less often).
  double get intensityScale => const [2.0, 1.0, 0.5][reviewIntensity.clamp(0, 2)];

  /// Whether the user has Qbit Pro. Currently persisted locally; on mobile this
  /// gets driven by RevenueCat's "pro" entitlement (see PurchaseService drop-in).
  bool isPro = false;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    locale = p.getString(_kLocale) ?? 'en';
    voiceOn = p.getBool(_kVoice) ?? true;
    isPro = p.getBool(_kPro) ?? false;
    remindersOn = p.getBool(_kReminders) ?? false;
    reminderHour = p.getInt(_kReminderHour) ?? 9;
    newPerDay = p.getInt(_kNewPerDay) ?? 20;
    reviewIntensity = p.getInt(_kIntensity) ?? 1;
    seenIntro = p.getBool(_kSeenIntro) ?? false;
    notifyListeners();
  }

  Future<void> markIntroSeen() async {
    seenIntro = true;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kSeenIntro, true);
  }

  Future<void> setNewPerDay(int n) async {
    newPerDay = n.clamp(5, 50);
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kNewPerDay, newPerDay);
  }

  Future<void> setReviewIntensity(int i) async {
    reviewIntensity = i.clamp(0, 2);
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kIntensity, reviewIntensity);
  }

  Future<void> setReminders(bool v) async {
    remindersOn = v;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kReminders, v);
  }

  Future<void> setReminderHour(int h) async {
    reminderHour = h;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kReminderHour, h);
  }

  Future<void> setPro(bool v) async {
    isPro = v;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kPro, v);
  }

  Future<void> setLocale(String l) async {
    if (locale == l) return;
    locale = l;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kLocale, l);
  }

  Future<void> toggleVoice() async {
    voiceOn = !voiceOn;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kVoice, voiceOn);
  }
}

/// App-wide singleton.
final appState = AppState();
