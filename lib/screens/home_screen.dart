import 'dart:async';

import 'package:flutter/material.dart';
import '../data/catalogue_ota.dart';
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
import '../services/widget_service.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import '../widgets/wordmark.dart';
import 'account_screen.dart';
import 'game_screen.dart';
import 'paywall_screen.dart';
import 'placement_screen.dart';
import 'sets_list_screen.dart';
import 'settings_screen.dart';

/// Thrown internally when a player dismisses the Resume/Start-New prompt
/// without choosing — signals "stay on the home screen, do nothing."
class _CancelOpen implements Exception {}

class HomeScreen extends StatefulWidget {
  final WordRepository repository;
  const HomeScreen({super.key, required this.repository});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final ProgressStore _store = ProgressStore();
  late Future<List<Word>> _future;
  Timer? _otaCheck;
  int _selected = 0;
  GameMode _gameType = GameMode.quickPlay;

  @override
  void initState() {
    super.initState();
    // Progress writes are debounced (they used to re-encode the whole word map
    // on every answer). That means the last few answers can still be in memory
    // when the OS takes the app away, so flush on the way out.
    WidgetsBinding.instance.addObserver(this);
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
    // Look for a newer word list — well after first frame, on a timer, never
    // awaited. Anything it finds is installed for the NEXT cold start; this
    // session keeps the catalogue it already parsed. See CatalogueOta.
    _otaCheck = CatalogueOta.instance.scheduleCheck();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _store.flush();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _otaCheck?.cancel();
    _store.dispose(); // flushes anything pending
    super.dispose();
  }

  /// Set once if [ProgressStore.load] had to reset a damaged section, so the
  /// learner is told rather than quietly wondering where their streak went.
  bool _dataResetDismissed = false;

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

  /// Review/Daily draw from one global deck, not a chosen track — matches the
  /// key GameScreen uses when saving/looking up an in-progress round.
  String _roundTrackId(GameMode mode) =>
      (mode == GameMode.review || mode == GameMode.daily)
          ? '_global'
          : kTracks[_selected].id;

  /// If there's a saved unfinished round for this track+mode, ask Resume vs
  /// Start New before dealing a fresh deck. Returns the snapshot to resume
  /// with (or null to start fresh), or throws _CancelOpen if the player
  /// dismissed the prompt without choosing (stay on the home screen).
  Future<Map<String, dynamic>?> _resolveResume(GameMode mode) async {
    final snap = _store.roundSnapshot(_roundTrackId(mode), mode.name);
    if (snap == null) return null;
    final locale = appState.locale;
    final total = (snap['deckIds'] as List).length;
    final cur = (((snap['index'] as num?)?.toInt() ?? 0) + 1).clamp(1, total);
    final score = (snap['score'] as num?)?.toInt() ?? 0;
    final resume = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF14141A),
        title: Text(Strings.t(locale, 'resumeRoundTitle'),
            style: QType.serif(size: 18, color: QColors.cream)),
        content: Text(
            Strings.t(locale, 'resumeRoundBody')
                .replaceFirst('{cur}', '$cur')
                .replaceFirst('{total}', '$total')
                .replaceFirst('{score}', '$score'),
            style: QType.sans(size: 13.5, color: QColors.muted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(Strings.t(locale, 'startNewRound').toUpperCase(),
                style: QType.mono(size: 11, color: QColors.dim, spacing: 1)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(Strings.t(locale, 'resumeRound').toUpperCase(),
                style: QType.mono(size: 11, color: QColors.coral, spacing: 1)),
          ),
        ],
      ),
    );
    if (resume == null) throw _CancelOpen(); // dismissed — stay on home
    if (resume) return snap;
    await _store.clearRoundSnapshot(_roundTrackId(mode), mode.name);
    return null;
  }

  Future<void> _openGame(List<Word> words, GameMode mode) async {
    Map<String, dynamic>? resumeSnapshot;
    try {
      resumeSnapshot = await _resolveResume(mode);
    } on _CancelOpen {
      return;
    }
    // _resolveResume() can show a dialog and await the answer, so this widget
    // may be gone by the time we get here.
    if (!mounted) return;
    await Navigator.of(context).push(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, __, ___) => GameScreen(
        words: words,
        track: kTracks[_selected],
        store: _store,
        mode: mode,
        resumeSnapshot: resumeSnapshot,
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

  /// Reverse, Listen and Spelling are Pro-gated; Classic Quick Play stays free.
  static bool _isProMode(GameMode m) =>
      m == GameMode.reverse || m == GameMode.listen || m == GameMode.spelling;

  /// Listen and Spelling hide the written word and ask the learner to decode
  /// or reproduce it, which is a much harder ask than picking from three
  /// meanings. Without a placement we cannot match difficulty, so these would
  /// deal words of unknown difficulty to a learner of unknown level — which is
  /// how a beginner ends up spelling a word they have never seen. Gating them
  /// on placement also gives the quiz a reward for finishing rather than only
  /// a prompt to start.
  static bool _needsLevel(GameMode m) =>
      m == GameMode.listen || m == GameMode.spelling;

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
  void _selectMode(GameMode m, List<Word> words) {
    if (_isProMode(m) && !appState.isPro) {
      _openPaywall();
    } else if (_needsLevel(m) && !_store.placed) {
      _openPlacement(words);
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
                  // Learner-readable, and it offers something to do. Damaged
                  // local progress no longer reaches here at all — load()
                  // recovers section by section — so this is now about the
                  // bundled catalogue, where retrying is the useful move.
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.refresh,
                              color: QColors.coral, size: 30),
                          const SizedBox(height: 14),
                          Text(Strings.t(locale, 'loadFailed'),
                              textAlign: TextAlign.center,
                              style: QType.sans(
                                  size: 14.5, color: QColors.ink, height: 1.45)),
                          const SizedBox(height: 18),
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: QColors.rule),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 22, vertical: 13),
                            ),
                            onPressed: () =>
                                setState(() => _future = _load()),
                            child: Text(Strings.t(locale, 'retry'),
                                style: QType.mono(
                                    size: 12, color: QColors.ink, spacing: 1.5)),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return Column(
                  children: [
                    if (_store.loadWarnings.isNotEmpty && !_dataResetDismissed)
                      _DataResetBanner(
                        locale: locale,
                        details: _store.loadWarnings,
                        onDismiss: () =>
                            setState(() => _dataResetDismissed = true),
                      ),
                    Expanded(
                      child: _buildHome(
                          context, snap.data ?? const <Word>[], locale),
                    ),
                  ],
                );
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
          const SizedBox(height: 6),
          Text(Strings.t(locale, 'answerLangHint'),
              style: QType.mono(size: 11.5, color: QColors.muted, spacing: 0.2, weight: FontWeight.w500),
              maxLines: 2),
          const SizedBox(height: 4),
          const Wordmark(size: 72),
          const SizedBox(height: 14),
          Text(Strings.t(locale, 'wordMastery'),
              style: QType.mono(size: 11.5, color: QColors.coral, spacing: 3)),
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
              style: QType.mono(size: 11, color: QColors.muted, spacing: 2.5)),
          const SizedBox(height: 10),
          _RuledList(children: [
            for (var i = 0; i < kTracks.length; i++)
              _TrackTile(
                track: kTracks[i],
                locale: locale,
                selected: i == _selected,
                onTap: () => setState(() => _selected = i),
              ),
          ]),
          const SizedBox(height: 20),
          _ModeChips(
            selected: _gameType,
            locale: locale,
            isPro: appState.isPro,
            placed: _store.placed,
            onSelect: (m) => _selectMode(m, words),
          ),
          const SizedBox(height: 20),
          _RuledList(children: [
            _ReviewButton(
              due: due,
              locale: locale,
              onTap: () => _openGame(words, GameMode.review),
            ),
            _MySetsButton(locale: locale, onTap: () => _openSets(words)),
          ]),
          const SizedBox(height: 22),
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
        borderRadius: BorderRadius.circular(kQRadius),
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
                      size: 12,
                      color: locale == l ? const Color(0xFF160603) : QColors.muted,
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
                style: QType.mono(size: 10.5, color: QColors.muted, spacing: 1.2)),
          ]),
        ),
      );
}

/// Plain vertical stack, no frame at all — spacing alone separates rows.
/// The rows themselves (below) are the "buttons": large type + color do
/// the work that a bordered card used to do.
class _RuledList extends StatelessWidget {
  final List<Widget> children;
  const _RuledList({required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          children[i],
          if (i < children.length - 1) const SizedBox(height: 2),
        ],
      ],
    );
  }
}

class _DailyBanner extends StatelessWidget {
  final String locale;
  final bool done;
  final VoidCallback onTap;
  const _DailyBanner({required this.locale, required this.done, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(children: [
          Icon(done ? Icons.check_circle : Icons.calendar_today_outlined,
              color: QColors.coral, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Strings.t(locale, 'dailyChallenge'),
                  style: QType.serif(size: 24, weight: FontWeight.w600, color: QColors.coral)),
              const SizedBox(height: 3),
              Text(Strings.t(locale, done ? 'dailyDone' : 'dailySub'),
                  style: QType.sans(size: 13, color: QColors.muted)),
            ]),
          ),
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
      case 'sat':
        return Icons.architecture_outlined;
      case 'gre':
        return Icons.school_outlined;
      case 'ielts':
        return Icons.menu_book_outlined;
      default:
        return Icons.gps_fixed;
    }
  }

  // Copy is keyed off the track id — `trackSat`, `trackSatSub` and so on — so
  // adding a track needs a strings entry rather than another ternary branch.
  String get _key =>
      'track${track.id[0].toUpperCase()}${track.id.substring(1)}';
  String get _title => Strings.t(locale, _key);
  String get _sub => Strings.t(locale, '${_key}Sub');

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          Icon(_icon, color: selected ? QColors.coral : QColors.dim, size: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_title,
                  style: QType.serif(
                      size: 22,
                      weight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? QColors.coral : QColors.cream)),
              const SizedBox(height: 2),
              Text(_sub.toUpperCase(),
                  style: QType.mono(size: 10.5, color: QColors.muted, spacing: 0.6)),
            ]),
          ),
        ]),
      ),
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
    final active = due > 0;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          Icon(Icons.school_outlined, color: active ? QColors.coral : QColors.dim, size: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: QType.serif(
                      size: 22,
                      weight: active ? FontWeight.w600 : FontWeight.w500,
                      color: active ? QColors.coral : QColors.cream)),
              const SizedBox(height: 2),
              Text(sub, style: QType.mono(size: 10.5, color: QColors.muted, spacing: 0.6)),
            ]),
          ),
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
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          const Icon(Icons.collections_bookmark_outlined,
              color: QColors.dim, size: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Strings.t(locale, 'mySets'),
                  style: QType.serif(size: 22, weight: FontWeight.w500, color: QColors.cream)),
              const SizedBox(height: 2),
              Text(Strings.t(locale, 'mySetsShort'),
                  style: QType.mono(size: 10.5, color: QColors.muted, spacing: 0.6)),
            ]),
          ),
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kQRadius)),
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
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(children: [
          const Icon(Icons.explore_outlined, color: QColors.amber, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Strings.t(locale, 'findLevel'),
                  style: QType.serif(size: 22, weight: FontWeight.w600, color: QColors.amber)),
              const SizedBox(height: 3),
              Text(Strings.t(locale, 'findLevelSub'),
                  style: QType.sans(size: 13, color: QColors.muted)),
              const SizedBox(height: 5),
              // Say what skipping costs. The card used to be a bare invitation,
              // which made it easy to dismiss as optional polish — it isn't:
              // without a rank we cannot match difficulty at all.
              Text(Strings.t(locale, 'findLevelWhy'),
                  style: QType.mono(size: 11, color: QColors.dim, spacing: 0.2)),
            ]),
          ),
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
  final bool placed;
  final ValueChanged<GameMode> onSelect;
  const _ModeChips({
    required this.selected,
    required this.locale,
    required this.isPro,
    required this.placed,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final items = <(GameMode, String)>[
      (GameMode.quickPlay, 'modeClassic'),
      (GameMode.reverse, 'modeReverse'),
      (GameMode.listen, 'modeListen'),
      (GameMode.spelling, 'modeSpelling'),
    ];
    // Plain text options, no container — size/weight/color signal selection.
    return Row(children: [
      for (var k = 0; k < items.length; k++)
        Expanded(
          child: GestureDetector(
            onTap: () => onSelect(items[k].$1),
            child: () {
              final mode = items[k].$1;
              final isSel = selected == mode;
              final proLocked = !isPro &&
                  (mode == GameMode.reverse ||
                      mode == GameMode.listen ||
                      mode == GameMode.spelling);
              // Listen/Spelling additionally wait on the placement quiz — see
              // _HomeScreenState._needsLevel.
              final levelLocked = !placed &&
                  (mode == GameMode.listen || mode == GameMode.spelling);
              final locked = proLocked || levelLocked;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    Text(Strings.t(locale, items[k].$2).toUpperCase(),
                        textAlign: TextAlign.center,
                        style: QType.mono(
                            size: 13,
                            weight: isSel ? FontWeight.w700 : FontWeight.w500,
                            color: isSel ? QColors.coral : QColors.dim,
                            spacing: 1.2)),
                    if (locked)
                      const Positioned(
                        top: -7,
                        right: 20,
                        child: Icon(Icons.lock, size: 10, color: QColors.coral),
                      ),
                  ],
                ),
              );
            }(),
          ),
        ),
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
          borderRadius: BorderRadius.circular(kQRadius),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.workspace_premium, size: 13, color: QColors.coral),
          const SizedBox(width: 5),
          Text(Strings.t(locale, 'goPro').toUpperCase(),
              style: QType.mono(size: 11, color: QColors.coral, spacing: 1.5)),
        ]),
      ),
    );
  }
}


/// A one-time notice that some saved data could not be read and was reset.
///
/// ProgressStore.load() now recovers section by section instead of throwing,
/// which is what stopped a single damaged byte from bricking the app — but
/// recovering silently would mean a learner's streak simply vanishes with no
/// explanation. Saying so once is the smaller cost.
class _DataResetBanner extends StatelessWidget {
  final String locale;
  final List<String> details;
  final VoidCallback onDismiss;

  const _DataResetBanner({
    required this.locale,
    required this.details,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: QColors.panel,
        border: Border.all(color: QColors.rule),
        borderRadius: BorderRadius.circular(kQRadius),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 17, color: QColors.amber),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(Strings.t(locale, 'dataResetNotice'),
                    style: QType.sans(
                        size: 13, color: QColors.ink, height: 1.4)),
                for (final d in details) ...[
                  const SizedBox(height: 4),
                  Text('· $d',
                      style: QType.sans(
                          size: 11.5, color: QColors.muted, height: 1.35)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Text(Strings.t(locale, 'dataResetDismiss'),
                  style: QType.mono(
                      size: 10, color: QColors.coral, spacing: 1.2)),
            ),
          ),
        ],
      ),
    );
  }
}
