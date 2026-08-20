import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../game/level.dart';

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
  static const _kDifficulty = 'qbit_difficulty_pref';

  String locale = 'en';
  bool voiceOn = true;

  /// Whether the player has been through the splash/intro screen. False on a
  /// brand-new install — that's when we show the differentiator pitch.
  bool seenIntro = false;

  /// Daily "word from your collection" reminders (mobile only).
  bool remindersOn = false;
  int reminderHour = 9; // local hour, 0–23

  /// Difficulty band served to the learner. Defaults to [DifficultyPref.auto],
  /// which derives the band from the placement rank — an explicit choice here
  /// overrides that.
  DifficultyPref difficultyPref = DifficultyPref.auto;

  /// Spaced-repetition dial.
  int newPerDay = 20; // new words introduced per day
  int reviewIntensity = 1; // 0 relaxed, 1 normal, 2 intense

  /// The recall probability FSRS aims for at each intensity.
  ///
  /// This used to be a raw interval multiplier (2.0 / 1.0 / 0.5). FSRS derives
  /// the interval from a retention target instead, which is both the correct
  /// input for the model and a more meaningful promise: "intense" now means
  /// "keep 95% of what you have learned", not "multiply everything by a half".
  /// Higher retention costs more reviews for less forgetting — that trade is
  /// the whole point of the control.
  double get retentionTarget =>
      const [0.85, 0.90, 0.95][reviewIntensity.clamp(0, 2)];

  /// Whether the user has Qulex Pro. Currently persisted locally; on mobile this
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
    final dIdx = p.getInt(_kDifficulty) ?? 0;
    difficultyPref =
        DifficultyPref.values[dIdx.clamp(0, DifficultyPref.values.length - 1)];
    notifyListeners();
  }

  Future<void> markIntroSeen() async {
    seenIntro = true;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kSeenIntro, true);
  }

  Future<void> setDifficultyPref(DifficultyPref d) async {
    if (difficultyPref == d) return;
    difficultyPref = d;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kDifficulty, d.index);
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
