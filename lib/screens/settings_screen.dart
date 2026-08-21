import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/progress_store.dart';
import '../game/level.dart';
import '../l10n/strings.dart';
import '../models/word.dart';
import '../services/notification_service.dart';
import '../services/offline_audio.dart';
import '../services/voice.dart';
import '../state/app_state.dart';
import '../a11y.dart';
import '../game/fsrs_optimiser.dart';
import '../data/review_log.dart';
import '../layout.dart';
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
      transitionDuration: A11y.duration(context, const Duration(milliseconds: 240)),
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
            // A settings page is a single stack of controls; widening it just
            // strands each toggle a long way from its label. It stays a
            // reading column and centres on a large display.
            return ReadingColumn(
                child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── header ──
                  Row(children: [
                    // The brand mark yields to the page title when the type is
                    // large. Which page you are on is information; which app
                    // you are in, on a screen you just navigated to, is not.
                    if (A11y.textScale(context) < 1.35) ...[
                      const Wordmark(size: 22),
                      const SizedBox(width: 10),
                    ],
                    // Flexible, not a bare Text followed by a Spacer: at 2x
                    // Dynamic Type "SETTINGS" in 13pt tracked-out mono is wide
                    // enough to push the close button off the right edge. It
                    // did — adaptive_frames_test.dart caught it at capture time
                    // as a 12px RenderFlex overflow.
                    Flexible(
                      child: Text(Strings.t(locale, 'settings').toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: QType.mono(
                              size: 13,
                              color: QColors.coral,
                              // 3pt of tracking on a 13pt word is 20% of its
                              // width; at 2x that is what pushed it into an
                              // ellipsis. Give the letters back their space
                              // when the type is already large.
                              spacing:
                                  A11y.textScale(context) >= 1.35 ? 1 : 3)),
                    ),
                    const Spacer(),
                    Semantics(
                      button: true,
                      label: Strings.t(locale, 'close'),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => Navigator.of(context).maybePop(),
                        child: const Icon(Icons.close, color: QColors.muted),
                      ),
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
                  _difficulty(locale),
                  _personalise(locale),
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
                      semanticLabel: Strings.t(locale, 'voice'),
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
                        semanticLabel: Strings.t(locale, 'dailyReminders'),
                      ),
                    ),
                  _offlineVoice(locale),
                  const SizedBox(height: 30),

                  // ── promise ──
                  QLabel(Strings.t(locale, 'qulexPromise')),
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
            ));
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
            style: QType.serif(size: 18, color: QColors.cream, height: 1.2)),
        const SizedBox(height: 3),
        Text(Strings.t(locale, 'reviewIntensitySub'),
            style: QType.sans(size: 13, color: QColors.dim, height: 1.4)),
        const SizedBox(height: 12),
        QSegment(
          labels: labels,
          index: appState.reviewIntensity,
          onChanged: (i) {
            appState.setReviewIntensity(i);
            widget.store.desiredRetention = appState.retentionTarget;
          },
        ),
        const SizedBox(height: 15),
        const QRule(),
      ],
    );
  }

  /// Difficulty band. Sits with the other learning dials rather than on the
  /// home screen, because "Auto" should be right for nearly everyone — the
  /// placement quiz already answers this question. It is here for the learner
  /// who disagrees with the placement, or who wants to be stretched.
  Widget _difficulty(String locale) {
    final labels = [
      Strings.t(locale, 'diffAuto'),
      Strings.t(locale, 'diffEasy'),
      Strings.t(locale, 'diffMedium'),
      Strings.t(locale, 'diffHard'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 15),
        Text(Strings.t(locale, 'difficultyTitle'),
            style: QType.serif(size: 18, color: QColors.cream, height: 1.2)),
        const SizedBox(height: 3),
        Text(Strings.t(locale, 'difficultySub'),
            style: QType.sans(size: 13, color: QColors.dim, height: 1.4)),
        const SizedBox(height: 12),
        QSegment(
          labels: labels,
          index: appState.difficultyPref.index,
          onChanged: (i) => appState.setDifficultyPref(
              DifficultyPref.values[i.clamp(0, DifficultyPref.values.length - 1)]),
        ),
        const SizedBox(height: 15),
        const QRule(),
      ],
    );
  }

  /// The offline-voice block: a description, a live progress line, a download
  /// or stop button, and the Wi-Fi top-up toggle.
  ///
  /// Deliberately one block rather than two rows. The toggle is meaningless on
  /// its own — "top up on Wi-Fi" tops up WHAT? — and a learner who has never
  /// downloaded anything needs to see the button and the switch together to
  /// understand that one is the manual version of the other.
  /// Retrains the scheduler on this learner's own history.
  ///
  /// Deliberately a manual action rather than something that happens quietly.
  /// Changing the scheduler changes when every word comes back; a learner who
  /// notices their reviews shifting should be able to point at the moment they
  /// asked for it. It also states the outcome plainly, INCLUDING when the fit
  /// was declined — "we tried and your own data did not beat the defaults" is a
  /// real result and hiding it would make the button feel broken.
  Widget _personalise(String locale) {
    final log = ReviewLog.instance;
    final ready = log.canFit;
    final sub = _fitMessage ??
        fitNoteText(locale, appState.fsrsFitNote) ??
        (ready
            ? Strings.t(locale, 'personaliseReady')
            : '${Strings.t(locale, 'personaliseLocked')} '
                '(${log.count}/${ReviewLog.fitThreshold})');
    return QRow(
      title: Strings.t(locale, 'personalise'),
      sub: sub,
      trailing: QButton(
        Strings.t(locale, appState.fsrsPersonalised ? 'personaliseAgain' : 'personaliseRun'),
        onTap: (!ready || _fitting) ? null : () => _runFit(locale),
      ),
    );
  }

  bool _fitting = false;
  String? _fitMessage;

  Future<void> _runFit(String locale) async {
    setState(() {
      _fitting = true;
      _fitMessage = Strings.t(locale, 'personaliseWorking');
    });
    try {
      final history = await ReviewLog.instance.readAll();
      // Off the UI isolate: sixty steps x thirty-eight replays of the whole
      // history is seconds of arithmetic, and doing it inline would freeze
      // Settings mid-tap.
      final result = await compute(FsrsOptimiser.fit, history);
      // The note is written before the mounted check on purpose. A learner who
      // backs out of Settings while sixty gradient steps are running has still
      // had the fit computed, and throwing the answer away would mean the next
      // visit says nothing happened.
      final note = fitNote(result);
      if (result.improved) await appState.setFsrsWeights(result.weights);
      await appState.setFsrsFitNote(note);
      // Whatever the outcome, the learner has now been in here and asked. The
      // banner has nothing left to tell them.
      await appState.markFsrsNudged();
      if (!mounted) return;
      setState(() => _fitMessage = fitNoteText(locale, note));
    } catch (_) {
      if (mounted) {
        setState(() => _fitMessage = Strings.t(locale, 'personaliseFailed'));
      }
    } finally {
      if (mounted) setState(() => _fitting = false);
    }
  }

  Widget _offlineVoice(String locale) {
    return ValueListenableBuilder<OfflineProgress>(
      valueListenable: OfflineAudio.instance.progress,
      builder: (context, prog, _) {
        final running = prog.running;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            QRow(
              title: Strings.t(locale, 'offlineVoice'),
              sub: Strings.t(locale, 'offlineVoiceSub'),
              trailing: QButton(
                Strings.t(locale, running ? 'offlineStop' : 'offlineDownload'),
                // Disabled with the voice off rather than hidden: hiding it
                // would leave someone wondering where the feature went, and
                // the reason is one row above.
                onTap: !appState.voiceOn
                    ? null
                    : (running
                        ? OfflineAudio.instance.cancel
                        : () => _startOfflineDownload(locale)),
              ),
            ),
            if (running || prog.total > 0 || prog.stoppedBecause != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (running) ...[
                      // Announced as a value rather than left as a bare bar,
                      // for the same reason the game's timer is.
                      Semantics(
                        label: Strings.t(locale, 'offlineVoice'),
                        value: '${(prog.fraction * 100).round()}%',
                        child: ExcludeSemantics(
                          child: LinearProgressIndicator(
                            value: prog.fraction,
                            minHeight: 2,
                            backgroundColor: const Color(0x1FFFFFFF),
                            valueColor: const AlwaysStoppedAnimation<Color>(
                                QColors.coral),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text('${prog.done} / ${prog.total}',
                          style: QType.mono(size: 11.5, color: QColors.muted)),
                    ] else
                      Text(
                        prog.stoppedBecause ??
                            '${prog.total} ${Strings.t(locale, 'offlineReady')}',
                        style: QType.sans(size: 13, color: QColors.muted),
                      ),
                    if (_cacheBytes != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${_mb(_cacheBytes!)} ${Strings.t(locale, 'offlineCacheUse')} '
                        '${_mb(Voice.instance.cacheCapacityBytes)}',
                        style: QType.mono(size: 11, color: QColors.dim),
                      ),
                    ],
                  ],
                ),
              ),
            QRow(
              title: Strings.t(locale, 'offlineAuto'),
              sub: Strings.t(locale, 'offlineAutoSub'),
              trailing: QToggle(
                value: appState.offlineAudioAuto,
                onChanged: (v) => appState.setOfflineAudioAuto(v),
                semanticLabel: Strings.t(locale, 'offlineAuto'),
              ),
              last: true,
            ),
          ],
        );
      },
    );
  }

  static String _mb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(bytes > 10 * 1024 * 1024 ? 0 : 1)}MB';

  int? _cacheBytes;

  Future<void> _startOfflineDownload(String locale) async {
    // The words the learner is actually about to meet — due reviews first,
    // then the new ones the daily cap will introduce. Downloading the whole
    // catalogue would be a 2.5M credit job for audio nobody has asked to hear.
    // Shared with the background top-up so the two cannot disagree.
    final plan =
        OfflineAudio.upcomingWords(widget.words, widget.store.progressFor);

    await OfflineAudio.instance.download(plan, locale: locale);
    final size = await Voice.instance.cacheSizeBytes();
    if (mounted) setState(() => _cacheBytes = size);
  }

  Widget _promise(IconData icon, String text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: QColors.coral),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: QType.sans(size: 15, color: QColors.muted, height: 1.45)),
          ),
        ],
      );
}

/// Encodes a fit outcome for storage. See [AppState.fsrsFitNote].
///
/// A code, not a sentence: 'ok:<percent>:<reviews>' or 'no:<FitDecline.name>'.
/// [FitResult.declined] carries the English prose and stays where it is useful
/// — tests and logs — but nothing a learner reads comes from it.
String fitNote(FitResult r) => r.improved
    ? 'ok:${r.improvementPercent.toStringAsFixed(0)}:${r.reviewsUsed}'
    : 'no:${(r.reason ?? FitDecline.noImprovement).name}';

/// Turns a stored [fitNote] back into a sentence in [locale].
///
/// Returns null for null or unreadable input rather than a placeholder, so the
/// caller falls back to the row's normal subtitle. A note written by a future
/// version, or half-written, must not turn the row into an error message.
String? fitNoteText(String locale, String? note) {
  if (note == null || note.isEmpty) return null;
  final parts = note.split(':');
  if (parts.length == 3 && parts.first == 'ok') {
    return '${Strings.t(locale, 'personaliseDone')} '
        '(${parts[1]}%, ${parts[2]})';
  }
  if (parts.length == 2 && parts.first == 'no') {
    return switch (parts[1]) {
      'tooFewReviews' => Strings.t(locale, 'personaliseDeclineFew'),
      'noHistory' => Strings.t(locale, 'personaliseDeclineNone'),
      'tooFewWords' => Strings.t(locale, 'personaliseDeclineWords'),
      'noGradable' => Strings.t(locale, 'personaliseDeclineUngradable'),
      'noImprovement' => Strings.t(locale, 'personaliseDeclineWorse'),
      _ => null,
    };
  }
  return null;
}
