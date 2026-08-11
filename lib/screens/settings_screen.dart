import 'package:flutter/material.dart';

import '../data/progress_store.dart';
import '../l10n/strings.dart';
import '../models/word.dart';
import '../services/notification_service.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import '../widgets/wordmark.dart';
import 'about_screen.dart';
import 'changelog_screen.dart';
import 'feedback_screen.dart';
import 'placement_screen.dart';
import 'privacy_screen.dart';
import 'security_screen.dart';
import 'splash_screen.dart';

/// Learner controls, rebuilt on the editorial UI kit: hairline-separated rows
/// under mono signpost labels, squared toggle / stepper / segmented controls,
/// no rounded outline cards or pills.
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

  void _open(Widget page) {
    Navigator.of(context).push(PageRouteBuilder(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: appState,
          builder: (context, _) {
            final locale = appState.locale;
            final n = widget.store.knownSuspendedCount();
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── header ──
                  Row(children: [
                    const Wordmark(size: 22),
                    const SizedBox(width: 10),
                    Text(Strings.t(locale, 'settings').toUpperCase(),
                        style: QType.mono(
                            size: 13, color: QColors.coral, spacing: 3)),
                    const Spacer(),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(context).maybePop(),
                      child: const Icon(Icons.close, color: QColors.muted),
                    ),
                  ]),
                  const SizedBox(height: 26),

                  // ── learning ──
                  QLabel(Strings.t(locale, 'learning')),
                  QRow(
                    title: Strings.t(locale, 'newPerDay'),
                    sub: Strings.t(locale, 'newPerDaySub'),
                    trailing: QStepper(
                      value: appState.newPerDay,
                      onMinus: () {
                        appState.setNewPerDay(appState.newPerDay - 5);
                        widget.store.newPerDay = appState.newPerDay;
                      },
                      onPlus: () {
                        appState.setNewPerDay(appState.newPerDay + 5);
                        widget.store.newPerDay = appState.newPerDay;
                      },
                    ),
                  ),
                  _intensity(locale),
                  QRow(
                    title: Strings.t(locale, 'resurface'),
                    sub: Strings.t(locale, 'resurfaceSub').replaceFirst('{n}', '$n'),
                    trailing: QButton(
                      Strings.t(locale, 'resurfaceBtn'),
                      onTap: n == 0
                          ? null
                          : () async {
                              final done =
                                  await widget.store.resurfaceMastered();
                              _snack(Strings.t(locale, 'resurfaceDone')
                                  .replaceFirst('{n}', '$done'));
                              if (mounted) setState(() {});
                            },
                    ),
                  ),
                  QRow(
                    icon: Icons.explore_outlined,
                    title: Strings.t(locale, 'findLevel'),
                    onTap: () => _open(PlacementScreen(
                        words: widget.words, store: widget.store)),
                    last: true,
                  ),
                  const SizedBox(height: 30),

                  // ── preferences ──
                  QLabel(Strings.t(locale, 'preferences')),
                  QRow(
                    title: Strings.t(locale, 'voice'),
                    sub: Strings.t(locale, 'voiceSub'),
                    trailing: QToggle(
                      value: appState.voiceOn,
                      onChanged: (_) => appState.toggleVoice(),
                    ),
                    last: !NotificationService.instance.supported,
                  ),
                  if (NotificationService.instance.supported)
                    QRow(
                      title: Strings.t(locale, 'dailyReminders'),
                      sub: Strings.t(locale, 'dailyRemindersSub'),
                      trailing: QToggle(
                        value: appState.remindersOn,
                        onChanged: (_) => _toggleReminders(),
                      ),
                      last: true,
                    ),
                  const SizedBox(height: 30),

                  // ── promise ──
                  QLabel(Strings.t(locale, 'qbitPromise')),
                  _promise(Icons.lock_open, Strings.t(locale, 'promiseFree')),
                  const SizedBox(height: 14),
                  _promise(
                      Icons.verified_outlined, Strings.t(locale, 'promiseKeep')),
                  const SizedBox(height: 30),

                  // ── about & legal ──
                  QLabel(Strings.t(locale, 'aboutLegal')),
                  QRow(
                      icon: Icons.info_outline,
                      title: Strings.t(locale, 'about'),
                      onTap: () => _open(const AboutScreen())),
                  QRow(
                      icon: Icons.play_circle_outline,
                      title: Strings.t(locale, 'replayIntro'),
                      onTap: () => _open(
                          const SplashScreen(fromSettings: true))),
                  QRow(
                      icon: Icons.privacy_tip_outlined,
                      title: Strings.t(locale, 'privacy'),
                      onTap: () => _open(const PrivacyScreen())),
                  QRow(
                      icon: Icons.shield_outlined,
                      title: Strings.t(locale, 'security'),
                      onTap: () => _open(const SecurityScreen())),
                  QRow(
                      icon: Icons.new_releases_outlined,
                      title: Strings.t(locale, 'whatsNew'),
                      onTap: () => _open(const ChangelogScreen())),
                  QRow(
                      icon: Icons.chat_bubble_outline,
                      title: Strings.t(locale, 'sendFeedback'),
                      onTap: () => _open(const FeedbackScreen()),
                      last: true),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _intensity(String locale) {
    final labels = [
      Strings.t(locale, 'relaxed'),
      Strings.t(locale, 'normal'),
      Strings.t(locale, 'intense'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 15),
        Text(Strings.t(locale, 'reviewIntensity'),
            style: QType.serif(size: 16.5, color: QColors.cream)),
        const SizedBox(height: 3),
        Text(Strings.t(locale, 'reviewIntensitySub'),
            style: QType.mono(size: 11.5, color: QColors.dim, spacing: 0.3)),
        const SizedBox(height: 12),
        QSegment(
          labels: labels,
          index: appState.reviewIntensity,
          onChanged: (i) {
            appState.setReviewIntensity(i);
            widget.store.intervalScale = appState.intensityScale;
          },
        ),
        const SizedBox(height: 15),
        const QRule(),
      ],
    );
  }

  Widget _promise(IconData icon, String text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: QColors.coral),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: QType.sans(size: 13.5, color: QColors.muted, height: 1.45)),
          ),
        ],
      );
}
