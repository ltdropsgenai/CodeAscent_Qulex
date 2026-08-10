import 'package:flutter/material.dart';

import '../data/progress_store.dart';
import '../l10n/strings.dart';
import '../models/word.dart';
import '../services/notification_service.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/wordmark.dart';
import 'about_screen.dart';
import 'changelog_screen.dart';
import 'feedback_screen.dart';
import 'placement_screen.dart';
import 'privacy_screen.dart';
import 'security_screen.dart';

/// Learner controls: the spaced-repetition dial (new-words/day + intensity),
/// re-surface mastered words, preferences (voice, daily reminders), and Qbit's
/// product promises. Progress lives in [store]; the dial + prefs in [appState].
class SettingsScreen extends StatefulWidget {
  final ProgressStore store;
  final List<Word> words;
  const SettingsScreen({super.key, required this.store, required this.words});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: QType.mono(size: 12, color: QColors.cream)),
      backgroundColor: const Color(0xFF14141A),
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _toggleReminders() async {
    final locale = appState.locale;
    if (appState.remindersOn) {
      await appState.setReminders(false);
      await NotificationService.instance.cancelAll();
      _snack(Strings.t(locale, 'remindersOff'));
    } else {
      final ok = await NotificationService.instance.requestPermission();
      if (!ok) {
        _snack(Strings.t(locale, 'remindersDenied'));
        return;
      }
      await appState.setReminders(true);
      await NotificationService.instance.rescheduleDailyWords(
        allWords: widget.words,
        store: widget.store,
        locale: locale,
        hour: appState.reminderHour,
      );
      _snack(Strings.t(locale, 'remindersOn'));
    }
    if (mounted) setState(() {});
  }

  Widget _toggleTile(String title, String sub, bool value, VoidCallback onTap) =>
      _panel(
        child: Row(children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: QType.serif(size: 16, color: QColors.cream)),
              const SizedBox(height: 2),
              Text(sub,
                  style: QType.mono(size: 10, color: QColors.dim, spacing: 0.3)),
            ]),
          ),
          Switch(
            value: value,
            activeColor: const Color(0xFF160603),
            activeTrackColor: QColors.coral,
            inactiveThumbColor: QColors.muted,
            inactiveTrackColor: QColors.panel,
            onChanged: (_) => onTap(),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: appState,
          builder: (context, _) {
            final locale = appState.locale;
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Wordmark(size: 22),
                    const SizedBox(width: 9),
                    Text(Strings.t(locale, 'settings').toUpperCase(),
                        style: QType.mono(
                            size: 14, color: QColors.coral, spacing: 3)),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close, color: QColors.muted),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  _label(locale, 'learning'),
                  const SizedBox(height: 12),
                  _newPerDay(locale),
                  const SizedBox(height: 14),
                  _intensity(locale),
                  const SizedBox(height: 14),
                  _resurface(locale),
                  const SizedBox(height: 9),
                  _navRow(Icons.explore_outlined, Strings.t(locale, 'findLevel'),
                      () => _open(PlacementScreen(
                          words: widget.words, store: widget.store))),
                  const SizedBox(height: 26),
                  _label(locale, 'preferences'),
                  const SizedBox(height: 12),
                  _toggleTile(
                    Strings.t(locale, 'voice'),
                    Strings.t(locale, 'voiceSub'),
                    appState.voiceOn,
                    () => appState.toggleVoice(),
                  ),
                  if (NotificationService.instance.supported) ...[
                    const SizedBox(height: 9),
                    _toggleTile(
                      Strings.t(locale, 'dailyReminders'),
                      Strings.t(locale, 'dailyRemindersSub'),
                      appState.remindersOn,
                      _toggleReminders,
                    ),
                  ],
                  const SizedBox(height: 26),
                  _label(locale, 'qbitPromise'),
                  const SizedBox(height: 12),
                  _promise(Icons.lock_open, Strings.t(locale, 'promiseFree')),
                  const SizedBox(height: 9),
                  _promise(Icons.verified_outlined, Strings.t(locale, 'promiseKeep')),
                  const SizedBox(height: 26),
                  _label(locale, 'aboutLegal'),
                  const SizedBox(height: 12),
                  _navRow(Icons.info_outline, Strings.t(locale, 'about'),
                      () => _open(const AboutScreen())),
                  const SizedBox(height: 9),
                  _navRow(Icons.privacy_tip_outlined,
                      Strings.t(locale, 'privacy'),
                      () => _open(const PrivacyScreen())),
                  const SizedBox(height: 9),
                  _navRow(Icons.shield_outlined, Strings.t(locale, 'security'),
                      () => _open(const SecurityScreen())),
                  const SizedBox(height: 9),
                  _navRow(Icons.new_releases_outlined,
                      Strings.t(locale, 'whatsNew'),
                      () => _open(const ChangelogScreen())),
                  const SizedBox(height: 9),
                  _navRow(Icons.chat_bubble_outline,
                      Strings.t(locale, 'sendFeedback'),
                      () => _open(const FeedbackScreen())),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _label(String locale, String key) => Text(
      Strings.t(locale, key).toUpperCase(),
      style: QType.mono(size: 10, color: QColors.dim, spacing: 2.5));

  void _open(Widget page) {
    Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    ));
  }

  Widget _navRow(IconData icon, String title, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: _panel(
          child: Row(children: [
            Icon(icon, size: 18, color: QColors.coral),
            const SizedBox(width: 13),
            Expanded(
              child: Text(title,
                  style: QType.serif(size: 16, color: QColors.cream)),
            ),
            const Icon(Icons.chevron_right, color: QColors.dim, size: 20),
          ]),
        ),
      );

  Widget _panel({required Widget child}) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        decoration: BoxDecoration(
          color: QColors.panel,
          border: Border.all(color: QColors.rule),
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      );

  Widget _newPerDay(String locale) {
    return _panel(
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(Strings.t(locale, 'newPerDay'),
                style: QType.serif(size: 16, color: QColors.cream)),
            const SizedBox(height: 2),
            Text(Strings.t(locale, 'newPerDaySub'),
                style: QType.mono(size: 10, color: QColors.dim, spacing: 0.3)),
          ]),
        ),
        _step(Icons.remove, () {
          appState.setNewPerDay(appState.newPerDay - 5);
          widget.store.newPerDay = appState.newPerDay;
        }),
        SizedBox(
          width: 40,
          child: Text('${appState.newPerDay}',
              textAlign: TextAlign.center,
              style: QType.serif(size: 22, color: QColors.coral)),
        ),
        _step(Icons.add, () {
          appState.setNewPerDay(appState.newPerDay + 5);
          widget.store.newPerDay = appState.newPerDay;
        }),
      ]),
    );
  }

  Widget _step(IconData icon, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: QColors.rule),
          ),
          child: Icon(icon, size: 18, color: QColors.muted),
        ),
      );

  Widget _intensity(String locale) {
    final labels = [
      Strings.t(locale, 'relaxed'),
      Strings.t(locale, 'normal'),
      Strings.t(locale, 'intense'),
    ];
    return _panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(Strings.t(locale, 'reviewIntensity'),
            style: QType.serif(size: 16, color: QColors.cream)),
        const SizedBox(height: 2),
        Text(Strings.t(locale, 'reviewIntensitySub'),
            style: QType.mono(size: 10, color: QColors.dim, spacing: 0.3)),
        const SizedBox(height: 12),
        Row(children: [
          for (var i = 0; i < 3; i++) ...[
            Expanded(
              child: GestureDetector(
                onTap: () {
                  appState.setReviewIntensity(i);
                  widget.store.intervalScale = appState.intensityScale;
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: appState.reviewIntensity == i
                        ? QColors.coral.withOpacity(0.14)
                        : Colors.transparent,
                    border: Border.all(
                        color: appState.reviewIntensity == i
                            ? QColors.coral
                            : QColors.rule),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(labels[i].toUpperCase(),
                      style: QType.mono(
                          size: 9.5,
                          color: appState.reviewIntensity == i
                              ? QColors.coral
                              : QColors.dim,
                          spacing: 1)),
                ),
              ),
            ),
            if (i < 2) const SizedBox(width: 8),
          ],
        ]),
      ]),
    );
  }

  Widget _resurface(String locale) {
    final n = widget.store.knownSuspendedCount();
    return _panel(
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(Strings.t(locale, 'resurface'),
                style: QType.serif(size: 16, color: QColors.cream)),
            const SizedBox(height: 2),
            Text(
                Strings.t(locale, 'resurfaceSub')
                    .replaceFirst('{n}', '$n'),
                style: QType.mono(size: 10, color: QColors.dim, spacing: 0.3)),
          ]),
        ),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: n > 0 ? QColors.coral : QColors.rule),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
          onPressed: n == 0
              ? null
              : () async {
                  final done = await widget.store.resurfaceMastered();
                  _snack(Strings.t(locale, 'resurfaceDone')
                      .replaceFirst('{n}', '$done'));
                  if (mounted) setState(() {});
                },
          child: Text(Strings.t(locale, 'resurfaceBtn').toUpperCase(),
              style: QType.mono(
                  size: 10.5,
                  color: n > 0 ? QColors.coral : QColors.dim,
                  spacing: 1)),
        ),
      ]),
    );
  }

  Widget _promise(IconData icon, String text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: QColors.coral),
          const SizedBox(width: 11),
          Expanded(
            child: Text(text,
                style: QType.sans(size: 13, color: QColors.muted, height: 1.45)),
          ),
        ],
      );
}
