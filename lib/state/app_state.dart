import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../game/srs.dart';

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
  static const _kOfflineAuto = 'qbit_offline_audio_auto';
  static const _kFsrsWeights = 'qbit_fsrs_weights';
  static const _kFsrsFitNote = 'qbit_fsrs_fit_note';
  static const _kFsrsNudged = 'qbit_fsrs_nudged';
  static const _kAccent = 'qbit_accent';

  String locale = 'en';
  bool voiceOn = true;

  /// Which English accent the cloud voice speaks in: 'us' or 'uk'.
  ///
  /// Defaults to 'us', which is the voice every clip in every cache was made
  /// with. Switching is not free and the cost is invisible: the voice id is
  /// part of both the server cache key and the on-device path, so a learner
  /// who switches starts from an empty cache and re-warms it one word at a
  /// time under the 600/day cap. Nobody who leaves this alone pays anything.
  ///
  /// Held as a string rather than an enum because it goes on the wire to the
  /// tts function, which resolves unknown values to its own default rather
  /// than failing — a client and a server disagreeing about an accent should
  /// produce the wrong accent, not silence.
  String accent = 'us';

  static const accents = ['us', 'uk'];

  /// Whether Qulex may quietly top up the offline voice cache in the
  /// background.
  ///
  /// Defaults to OFF, and stays off until someone says otherwise. Downloading
  /// audio nobody asked for is the kind of thing that turns up on a data bill,
  /// and the fact that it is gated on an unmetered connection is a promise made
  /// by code the learner cannot see. Opt-in is the only honest default.
  bool offlineAudioAuto = false;

  /// FSRS weights fitted to this learner, or null while the published defaults
  /// are in force. Stored as a comma-separated list rather than JSON because it
  /// is nineteen doubles and nothing else, forever.
  List<double>? fsrsWeights;

  bool get fsrsPersonalised => fsrsWeights != null;

  /// What the last fit actually did, in a form that survives leaving Settings.
  ///
  /// Stored as a code rather than a sentence — 'ok:14:823', or 'no:' plus a
  /// [FitDecline] name — because the learner can change language afterwards and
  /// a saved English sentence would still be English tomorrow. Settings turns
  /// it back into words at the moment it draws the row.
  ///
  /// This exists because the outcome used to live in a State field: run a fit,
  /// read "no better than the defaults", leave the screen, and the result was
  /// gone. Next visit the button looked untouched, so the honest answer read as
  /// a button that had done nothing.
  String? fsrsFitNote;

  /// Whether the learner has already been told personalisation is available.
  ///
  /// One-shot. Crossing the review threshold is worth interrupting for once;
  /// a banner that comes back every launch until you obey it is nagging.
  bool fsrsNudged = false;

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
    final a = p.getString(_kAccent);
    accent = accents.contains(a) ? a! : 'us';
    isPro = p.getBool(_kPro) ?? false;
    remindersOn = p.getBool(_kReminders) ?? false;
    reminderHour = p.getInt(_kReminderHour) ?? 9;
    newPerDay = p.getInt(_kNewPerDay) ?? 20;
    reviewIntensity = p.getInt(_kIntensity) ?? 1;
    offlineAudioAuto = p.getBool(_kOfflineAuto) ?? false;
    // Applied to the scheduler as it is read, so a personalised learner is
    // personalised from the first question of the session rather than from
    // whenever something happens to touch Settings.
    fsrsWeights = null;
    final raw = p.getString(_kFsrsWeights);
    if (raw != null) {
      final parsed = raw.split(',').map(double.tryParse).toList();
      if (!parsed.contains(null)) {
        final vals = parsed.cast<double>();
        if (Fsrs.usePersonalised(vals)) fsrsWeights = vals;
      }
    }
    if (fsrsWeights == null) Fsrs.useDefaults();
    fsrsFitNote = p.getString(_kFsrsFitNote);
    fsrsNudged = p.getBool(_kFsrsNudged) ?? false;
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

  Future<void> setOfflineAudioAuto(bool v) async {
    offlineAudioAuto = v;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kOfflineAuto, v);
  }

  /// Records the outcome of the last fit. See [fsrsFitNote] for the format.
  Future<void> setFsrsFitNote(String? note) async {
    fsrsFitNote = note;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    if (note == null) {
      await p.remove(_kFsrsFitNote);
    } else {
      await p.setString(_kFsrsFitNote, note);
    }
  }

  /// Marks the personalisation nudge as spent. Never unset — see [fsrsNudged].
  Future<void> markFsrsNudged() async {
    if (fsrsNudged) return;
    fsrsNudged = true;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kFsrsNudged, true);
  }

  /// Adopts fitted weights, or clears them when [values] is null.
  Future<void> setFsrsWeights(List<double>? values) async {
    final p = await SharedPreferences.getInstance();
    if (values == null || !Fsrs.usePersonalised(values)) {
      Fsrs.useDefaults();
      fsrsWeights = null;
      await p.remove(_kFsrsWeights);
    } else {
      fsrsWeights = values;
      await p.setString(_kFsrsWeights, values.join(','));
    }
    notifyListeners();
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

  /// Pick the accent the cloud voice speaks in. Ignores anything not in
  /// [accents] rather than storing a value the server would refuse.
  Future<void> setAccent(String a) async {
    if (!accents.contains(a) || a == accent) return;
    accent = a;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kAccent, a);
  }
}

/// App-wide singleton.
final appState = AppState();
