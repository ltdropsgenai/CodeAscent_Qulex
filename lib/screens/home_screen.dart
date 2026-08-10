import 'package:flutter/material.dart';
import '../data/progress_store.dart';
import '../data/word_repository.dart';
import '../game/daily.dart';
import '../game/game_controller.dart';
import '../game/track.dart';
import '../l10n/strings.dart';
import '../models/word.dart';
import '../services/auth_service.dart';
import '../services/notification_service.dart';
import '../services/sync_service.dart';
import '../services/voice.dart';
import '../services/widget_service.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/wordmark.dart';
import 'account_screen.dart';
import 'game_screen.dart';
import 'paywall_screen.dart';
import 'placement_screen.dart';
import 'sets_list_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  final WordRepository repository;
  const HomeScreen({super.key, required this.repository});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ProgressStore _store = ProgressStore();
  late Future<List<Word>> _future;
  int _selected = 0;
  GameMode _gameType = GameMode.quickPlay;

  @override
  void initState() {
    super.initState();
    SyncService.instance.attach(_store);
    _future = _load();
    // Once local is ready: pull cloud progress if signed in, and refresh the
    // daily word reminders so they always point at the user's current pile.
    _future.then((words) async {
      if (AuthService.instance.isSignedIn) {
        await SyncService.instance.syncNow();
        if (mounted) setState(() {});
      }
      if (appState.remindersOn) {
        await NotificationService.instance.rescheduleDailyWords(
          allWords: words,
          store: _store,
          locale: appState.locale,
          hour: appState.reminderHour,
        );
      }
      WidgetService.instance
          .update(words: words, store: _store, locale: appState.locale);
    }).catchError((_) {});
  }

  Future<List<Word>> _load() async {
    await _store.load();
    // Apply the learner's spaced-repetition dial to the store.
    _store.newPerDay = appState.newPerDay;
    _store.intervalScale = appState.intensityScale;
    return widget.repository.loadAll();
  }

  Future<void> _openSettings(List<Word> words) async {
    await Navigator.of(context).push(PageRouteBuilder(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) => SettingsScreen(store: _store, words: words),
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    ));
    // Re-apply in case the dial changed while we were away.
    _store.newPerDay = appState.newPerDay;
    _store.intervalScale = appState.intensityScale;
    if (mounted) setState(() {});
  }

  Future<void> _openGame(List<Word> words, GameMode mode) async {
    await Navigator.of(context).push(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, __, ___) => GameScreen(
        words: words,
        track: kTracks[_selected],
        store: _store,
        mode: mode,
      ),
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    ));
    // Mirror any newly earned progress to the cloud (best-effort).
    if (AuthService.instance.isSignedIn) SyncService.instance.pushProgress();
    // Refresh reminders so they track the freshly-updated review pile.
    if (appState.remindersOn) {
      NotificationService.instance.rescheduleDailyWords(
        allWords: words,
        store: _store,
        locale: appState.locale,
        hour: appState.reminderHour,
      );
    }
    WidgetService.instance
        .update(words: words, store: _store, locale: appState.locale);
    if (mounted) setState(() {});
  }

  Future<void> _openPlacement(List<Word> words) async {
    await Navigator.of(context).push(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, __, ___) =>
          PlacementScreen(words: words, store: _store),
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _openSets(List<Word> words) async {
    await Navigator.of(context).push(PageRouteBuilder(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (_, __, ___) =>
          SetsListScreen(library: words, store: _store),
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _openAccount() async {
    await Navigator.of(context).push(PageRouteBuilder(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) => const AccountScreen(),
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    ));
    if (mounted) setState(() {});
  }

  /// Reverse and Listen are Pro-gated; Classic Quick Play stays free.
  static bool _isProMode(GameMode m) =>
      m == GameMode.reverse || m == GameMode.listen;

  Future<void> _openPaywall() async {
    await Navigator.of(context).push(PageRouteBuilder(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) => const PaywallScreen(),
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    ));
    if (mounted) setState(() {});
  }

  /// Called when Start is pressed. Free modes launch; Pro modes launch only if
  /// the user has Pro — otherwise the paywall opens.
  void _startSelected(List<Word> words) {
    if (_isProMode(_gameType) && !appState.isPro) {
      _openPaywall();
    } else {
      _openGame(words, _gameType);
    }
  }

  /// Called when a mode chip is tapped. Selecting a Pro mode while not Pro opens
  /// the paywall instead of arming a mode the user can't start.
  void _selectMode(GameMode m) {
    if (_isProMode(m) && !appState.isPro) {
      _openPaywall();
    } else {
      setState(() => _gameType = m);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) => _scaffold(context, appState.locale),
    );
  }

  Widget _scaffold(BuildContext context, String locale) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: FutureBuilder<List<Word>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(
                      child: CircularProgressIndicator(color: QColors.coral));
                }
                if (snap.hasError) {
                  return Center(
                      child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Failed to load:\n${snap.error}',
                        textAlign: TextAlign.center,
                        style: QType.sans(color: QColors.coral)),
                  ));
                }
                return _buildHome(context, snap.data ?? const <Word>[], locale);
              },
            ),
          ),
    );
  }

  Widget _buildHome(BuildContext context, List<Word> words, String locale) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final due = _store.dueCount(now);
    final known = _store.knownCount();
    final streak = _store.profile.streak;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // language + voice controls
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: _LangToggle(locale: locale),
                ),
              ),
              const SizedBox(width: 8),
              if (!appState.isPro) ...[
                _GoProChip(locale: locale, onTap: _openPaywall),
                const SizedBox(width: 6),
              ],
              if (AuthService.instance.enabled)
                IconButton(
                  onPressed: _openAccount,
                  icon: Icon(
                      AuthService.instance.isSignedIn
                          ? Icons.account_circle
                          : Icons.account_circle_outlined,
                      color: AuthService.instance.isSignedIn
                          ? QColors.coral
                          : QColors.dim,
                      size: 22),
                ),
              IconButton(
                onPressed: () => _openSettings(words),
                icon: const Icon(Icons.tune, color: QColors.dim, size: 21),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Wordmark(size: 72),
          const SizedBox(height: 14),
          Text(Strings.t(locale, 'wordMastery'),
              style: QType.mono(size: 10.5, color: QColors.coral, spacing: 3)),
          const SizedBox(height: 10),
          Text(Strings.t(locale, 'tagline'),
              style: QType.serif(size: 23, weight: FontWeight.w500, color: QColors.ink, height: 1.25)),
          const SizedBox(height: 22),
          _StatStrip(vocabRank: _store.vocabRank(), streak: streak, known: known, locale: locale),
          const SizedBox(height: 20),
          _DailyBanner(
            locale: locale,
            done: _store.dailyDoneToday(ymd(DateTime.now())),
            onTap: () => _openGame(words, GameMode.daily),
          ),
          const SizedBox(height: 20),
          if (!_store.placed) ...[
            _PlacementCard(locale: locale, onTap: () => _openPlacement(words)),
            const SizedBox(height: 20),
          ],
          Text(Strings.t(locale, 'quickPlay').toUpperCase(),
              style: QType.mono(size: 10, color: QColors.dim, spacing: 2.5)),
          const SizedBox(height: 12),
          for (var i = 0; i < kTracks.length; i++)
            _TrackTile(
              track: kTracks[i],
              locale: locale,
              selected: i == _selected,
              onTap: () => setState(() => _selected = i),
            ),
          const SizedBox(height: 6),
          _ModeChips(
            selected: _gameType,
            locale: locale,
            isPro: appState.isPro,
            onSelect: _selectMode,
          ),
          const SizedBox(height: 12),
          _ReviewButton(
            due: due,
            locale: locale,
            onTap: () => _openGame(words, GameMode.review),
          ),
          const SizedBox(height: 9),
          _MySetsButton(locale: locale, onTap: () => _openSets(words)),
          const SizedBox(height: 18),
          _CoralButton(
            label: Strings.t(locale, 'startQuickPlay'),
            onPressed: words.isEmpty ? null : () => _startSelected(words),
          ),
        ],
      ),
    );
  }
}

class _LangToggle extends StatelessWidget {
  final String locale;
  const _LangToggle({required this.locale});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: QColors.rule),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final l in Strings.supported)
          GestureDetector(
            onTap: () => appState.setLocale(l),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: locale == l ? QColors.coral : Colors.transparent,
              child: Text(l.toUpperCase(),
                  style: QType.mono(
                      size: 11,
                      color: locale == l ? const Color(0xFF160603) : QColors.dim,
                      spacing: 1)),
            ),
          ),
      ]),
    );
  }
}

class _StatStrip extends StatelessWidget {
  final int vocabRank, streak, known;
  final String locale;
  const _StatStrip({required this.vocabRank, required this.streak, required this.known, required this.locale});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: QColors.rule),
          bottom: BorderSide(color: QColors.rule),
        ),
      ),
      child: Row(children: [
        _cell('$vocabRank', Strings.t(locale, 'vocabRank'), QColors.cream),
        _div(),
        _cell('$streak', Strings.t(locale, 'dayStreak'), QColors.coral),
        _div(),
        _cell('$known', Strings.t(locale, 'wordsKnown'), QColors.cream),
      ]),
    );
  }

  Widget _div() => Container(width: 1, height: 40, color: QColors.rule);

  Widget _cell(String n, String l, Color c) => Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 13),
          child: Column(children: [
            Text(n, style: QType.serif(size: 22, color: c)),
            const SizedBox(height: 3),
            Text(l.toUpperCase(),
                textAlign: TextAlign.center,
                style: QType.mono(size: 8.5, color: QColors.dim, spacing: 1.2)),
          ]),
        ),
      );
}

class _DailyBanner extends StatelessWidget {
  final String locale;
  final bool done;
  final VoidCallback onTap;
  const _DailyBanner({required this.locale, required this.done, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: QColors.coral.withOpacity(0.06),
          border: Border.all(color: QColors.coral),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          Icon(done ? Icons.check_circle : Icons.calendar_today_outlined,
              color: QColors.coral, size: 20),
          const SizedBox(width: 13),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Strings.t(locale, 'dailyChallenge').toUpperCase(),
                  style: QType.mono(size: 11, color: QColors.coral, spacing: 2)),
              const SizedBox(height: 2),
              Text(Strings.t(locale, done ? 'dailyDone' : 'dailySub'),
                  style: QType.sans(size: 12.5, color: QColors.muted)),
            ]),
          ),
          const Icon(Icons.chevron_right, color: QColors.coral),
        ]),
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  final Track track;
  final String locale;
  final bool selected;
  final VoidCallback onTap;
  const _TrackTile({required this.track, required this.locale, required this.selected, required this.onTap});

  IconData get _icon {
    switch (track.id) {
      case 'esl':
        return Icons.public;
      case 'test':
        return Icons.school_outlined;
      default:
        return Icons.gps_fixed;
    }
  }

  String get _title => Strings.t(locale,
      track.id == 'esl' ? 'trackEsl' : track.id == 'test' ? 'trackTest' : 'trackFun');
  String get _sub => Strings.t(locale,
      track.id == 'esl' ? 'trackEslSub' : track.id == 'test' ? 'trackTestSub' : 'trackFunSub');

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: QColors.panel,
            border: Border.all(color: selected ? QColors.coral : QColors.rule),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(children: [
            Icon(_icon, color: QColors.coral, size: 20),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_title, style: QType.serif(size: 16.5, color: QColors.cream)),
                const SizedBox(height: 3),
                Text(_sub.toUpperCase(),
                    style: QType.mono(size: 10, color: QColors.dim, spacing: 1)),
              ]),
            ),
            _Radio(selected: selected),
          ]),
        ),
      ),
    );
  }
}

class _Radio extends StatelessWidget {
  final bool selected;
  const _Radio({required this.selected});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: selected ? QColors.coral : QColors.rule),
      ),
      child: selected
          ? Center(
              child: Container(
                  width: 8, height: 8, decoration: const BoxDecoration(shape: BoxShape.circle, color: QColors.coral)))
          : null,
    );
  }
}

class _ReviewButton extends StatelessWidget {
  final int due;
  final String locale;
  final VoidCallback onTap;
  const _ReviewButton({required this.due, required this.locale, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final label = due > 0
        ? Strings.t(locale, 'reviewDue').replaceFirst('{n}', '$due')
        : Strings.t(locale, 'learnNew');
    final sub = due > 0 ? Strings.t(locale, 'reviewSub') : Strings.t(locale, 'learnSub');
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: QColors.panel,
          border: Border.all(color: due > 0 ? QColors.coral : QColors.rule),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          Icon(Icons.school_outlined, color: due > 0 ? QColors.coral : QColors.muted, size: 20),
          const SizedBox(width: 13),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: QType.serif(size: 16, color: QColors.cream)),
              const SizedBox(height: 2),
              Text(sub, style: QType.mono(size: 10, color: QColors.dim, spacing: 1)),
            ]),
          ),
          const Icon(Icons.chevron_right, color: QColors.dim),
        ]),
      ),
    );
  }
}

class _MySetsButton extends StatelessWidget {
  final String locale;
  final VoidCallback onTap;
  const _MySetsButton({required this.locale, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: QColors.panel,
          border: Border.all(color: QColors.rule),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          const Icon(Icons.collections_bookmark_outlined,
              color: QColors.coral, size: 20),
          const SizedBox(width: 13),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Strings.t(locale, 'mySets'),
                  style: QType.serif(size: 16, color: QColors.cream)),
              const SizedBox(height: 2),
              Text(Strings.t(locale, 'mySetsShort'),
                  style: QType.mono(size: 10, color: QColors.dim, spacing: 1)),
            ]),
          ),
          const Icon(Icons.chevron_right, color: QColors.dim),
        ]),
      ),
    );
  }
}

class _CoralButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  const _CoralButton({required this.label, required this.onPressed});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: QColors.coral,
          disabledBackgroundColor: QColors.coral.withOpacity(0.25),
          foregroundColor: const Color(0xFF160603),
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        onPressed: onPressed,
        child: Text(label.toUpperCase(), style: QType.mono(size: 13, color: const Color(0xFF160603), spacing: 2)),
      ),
    );
  }
}

/// "Find your level" card, shown until the learner completes placement.
class _PlacementCard extends StatelessWidget {
  final String locale;
  final VoidCallback onTap;
  const _PlacementCard({required this.locale, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: QColors.amber.withOpacity(0.07),
          border: Border.all(color: QColors.amber),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          const Icon(Icons.explore_outlined, color: QColors.amber, size: 20),
          const SizedBox(width: 13),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Strings.t(locale, 'findLevel').toUpperCase(),
                  style: QType.mono(size: 11, color: QColors.amber, spacing: 2)),
              const SizedBox(height: 2),
              Text(Strings.t(locale, 'findLevelSub'),
                  style: QType.sans(size: 12.5, color: QColors.muted)),
            ]),
          ),
          const Icon(Icons.chevron_right, color: QColors.amber),
        ]),
      ),
    );
  }
}

/// Quick Play game-type selector: Classic / Reverse / Listen.
class _ModeChips extends StatelessWidget {
  final GameMode selected;
  final String locale;
  final bool isPro;
  final ValueChanged<GameMode> onSelect;
  const _ModeChips({
    required this.selected,
    required this.locale,
    required this.isPro,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final items = <(GameMode, IconData, String)>[
      (GameMode.quickPlay, Icons.style_outlined, 'modeClassic'),
      (GameMode.reverse, Icons.swap_horiz, 'modeReverse'),
      (GameMode.listen, Icons.headphones_outlined, 'modeListen'),
    ];
    return Row(children: [
      for (var k = 0; k < items.length; k++) ...[
        Expanded(
          child: GestureDetector(
            onTap: () => onSelect(items[k].$1),
            child: () {
              final mode = items[k].$1;
              final isSel = selected == mode;
              final locked =
                  !isPro && (mode == GameMode.reverse || mode == GameMode.listen);
              return Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: isSel ? QColors.coral.withOpacity(0.12) : QColors.panel,
                  border: Border.all(color: isSel ? QColors.coral : QColors.rule),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(items[k].$2,
                          size: 18,
                          color: isSel ? QColors.coral : QColors.muted),
                      if (locked)
                        Positioned(
                          right: -9,
                          top: -6,
                          child: const Icon(Icons.lock,
                              size: 10, color: QColors.coral),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(Strings.t(locale, items[k].$3).toUpperCase(),
                      style: QType.mono(
                          size: 9,
                          color: isSel ? QColors.coral : QColors.dim,
                          spacing: 1)),
                ]),
              );
            }(),
          ),
        ),
        if (k < items.length - 1) const SizedBox(width: 8),
      ],
    ]);
  }
}

/// Small "Go Pro" pill in the top controls, shown only when the user is free.
class _GoProChip extends StatelessWidget {
  final String locale;
  final VoidCallback onTap;
  const _GoProChip({required this.locale, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: QColors.coral.withOpacity(0.12),
          border: Border.all(color: QColors.coral),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.workspace_premium, size: 13, color: QColors.coral),
          const SizedBox(width: 5),
          Text(Strings.t(locale, 'goPro').toUpperCase(),
              style: QType.mono(size: 10, color: QColors.coral, spacing: 1.5)),
        ]),
      ),
    );
  }
}
