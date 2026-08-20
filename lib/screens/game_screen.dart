import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/progress_store.dart';
import '../game/game_controller.dart';
import '../game/track.dart';
import '../l10n/strings.dart';
import '../models/word.dart';
import '../services/tutor.dart';
import '../services/voice.dart';
import '../state/app_state.dart';
import '../a11y.dart';
import '../layout.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import '../widgets/wordmark.dart';
import 'pronounce_screen.dart';

class GameScreen extends StatefulWidget {
  final List<Word> words;
  final Track track;
  final ProgressStore store;
  final GameMode mode;
  final bool recordProgress;

  /// A previously-saved mid-round snapshot to resume instead of dealing a
  /// fresh round (see ProgressStore.roundSnapshot / HomeScreen's resume
  /// prompt). Null starts a normal fresh round.
  final Map<String, dynamic>? resumeSnapshot;

  const GameScreen({
    super.key,
    required this.words,
    required this.track,
    required this.store,
    this.mode = GameMode.quickPlay,
    this.recordProgress = true,
    this.resumeSnapshot,
  });

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  late final GameController c;

  /// Key under which this track+mode's in-progress round is saved, so we can
  /// resume it later — only meaningful when [widget.recordProgress] is true
  /// (custom/one-off sets don't track progress and aren't resumable). Review
  /// and Daily draw from one global rotating deck, not a chosen track, so
  /// they share a single key regardless of which track chip was selected.
  String get _trackKey =>
      (widget.mode == GameMode.review || widget.mode == GameMode.daily)
          ? '_global'
          : widget.track.id;
  String get _modeKey => widget.mode.name;

  @override
  void initState() {
    super.initState();
    c = GameController(widget.words,
        store: widget.store,
        locale: appState.locale,
        mode: widget.mode,
        recordProgress: widget.recordProgress,
        difficultyPref: appState.difficultyPref);
    c.onFinished = () {
      if (widget.recordProgress) {
        widget.store.clearRoundSnapshot(_trackKey, _modeKey);
      }
    };
    var resumed = false;
    if (widget.resumeSnapshot != null) {
      try {
        c.resume(widget.resumeSnapshot!);
        resumed = true;
      } catch (_) {
        // Saved words are no longer available (library changed) — fall
        // through to a fresh round below.
      }
    }
    if (!resumed) c.start(widget.track);
  }

  @override
  void dispose() {
    Voice.instance.stop();
    // Saves are debounced now, so the last answers of a round may still be
    // sitting in memory when the screen goes away. Push them through.
    widget.store.flush();
    c.dispose();
    super.dispose();
  }

  /// Exit the round: if it's unfinished, save a snapshot so the player is
  /// offered Resume next time they pick this same track+mode, then leave.
  /// Confirms first so an accidental back-tap doesn't feel like data loss.
  Future<void> _confirmExit(BuildContext context) async {
    if (c.phase == Phase.finished) {
      Navigator.of(context).pop();
      return;
    }
    final locale = c.locale;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF14141A),
        title: Text(Strings.t(locale, 'exitRoundTitle'),
            style: QType.serif(size: 18, color: QColors.cream)),
        content: Text(Strings.t(locale, 'exitRoundBody'),
            style: QType.sans(size: 13.5, color: QColors.muted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(Strings.t(locale, 'cancel').toUpperCase(),
                style: QType.mono(size: 11, color: QColors.dim, spacing: 1)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(Strings.t(locale, 'exitRound').toUpperCase(),
                style: QType.mono(size: 11, color: QColors.coral, spacing: 1)),
          ),
        ],
      ),
    );
    if (leave != true) return;
    if (widget.recordProgress && c.inProgress) {
      await widget.store.saveRoundSnapshot(_trackKey, _modeKey, c.snapshot());
    }
    if (context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _confirmExit(context);
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            const _GameScrim(),
            SafeArea(
              child: AnimatedBuilder(
                animation: c,
                builder: (context, _) {
                  // No deck could be dealt at all — show why, and a way out.
                  // A scoreboard for zero questions is not an explanation.
                  if (c.dealtEmpty) {
                    return _EmptyDeckView(
                      locale: c.locale,
                      canResurface: widget.store.allSuspended,
                      onResurface: () async {
                        await widget.store.resurfaceMastered();
                        if (!mounted) return;
                        c.start(widget.track);
                      },
                      onChangePath: () => Navigator.of(context).pop(),
                    );
                  }
                  if (c.phase == Phase.finished) {
                    return _ResultView(
                      c: c,
                      onPlayAgain: () => c.start(widget.track),
                      onChangePath: () => Navigator.of(context).pop(),
                    );
                  }
                  return _GameView(c: c, onExit: () => _confirmExit(context));
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GameView extends StatefulWidget {
  final GameController c;
  final VoidCallback onExit;
  const _GameView({required this.c, required this.onExit});

  @override
  State<_GameView> createState() => _GameViewState();
}

class _GameViewState extends State<_GameView> {
  // Owned here (not in GameController) so it's purely a UI concern, and kept
  // alive across the ~60x/sec rebuilds the countdown timer drives — a fresh
  // TextEditingController every rebuild would reset the cursor/typed text.
  final _spellCtrl = TextEditingController();
  int? _shownForIndex;

  @override
  void dispose() {
    _spellCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final onExit = widget.onExit;
    // New question dealt (including the very first) -> clear any leftover text.
    if (_shownForIndex != c.index) {
      _shownForIndex = c.index;
      _spellCtrl.clear();
    }
    final locale = c.locale;
    final w = c.current;
    final g = w.glossFor(locale);
    final revealed = c.phase == Phase.revealed;

    // A question is one prompt and three answers stacked vertically. It reads
    // no better at 1,100pt than at 720, so on a wide display it centres rather
    // than stretching the answer rows into runways.
    return ReadingColumn(
      maxWidth: 720,
      child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // HUD
          Row(children: [
            IconButton(
              onPressed: onExit,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              tooltip: Strings.t(locale, 'a11yQuit'),
              icon: Icon(Icons.arrow_back,
                  color: QColors.muted,
                  size: 19,
                  semanticLabel: Strings.t(locale, 'a11yQuit')),
            ),
            const SizedBox(width: 4),
            const Wordmark(size: 19),
            const Spacer(),
            Semantics(
              label: Strings.t(locale, 'a11yStreak'),
              value: '${c.streak}',
              child:
                  ExcludeSemantics(child: _stat('${c.streak}', QColors.coral)),
            ),
            ExcludeSemantics(
              child: Container(
                  width: 1,
                  height: 16,
                  color: QColors.rule,
                  margin: const EdgeInsets.symmetric(horizontal: 12)),
            ),
            Semantics(
              label: Strings.t(locale, 'a11yScore'),
              value: '${c.score}',
              child: ExcludeSemantics(
                  child: _stat('${c.score}', const Color(0xFF7FA6FF))),
            ),
            AnimatedBuilder(
              animation: appState,
              builder: (_, __) => Semantics(
                toggled: appState.voiceOn,
                label: Strings.t(locale, 'voice'),
                child: IconButton(
                  onPressed: () => appState.toggleVoice(),
                  tooltip: Strings.t(locale, 'voice'),
                  icon: Icon(
                      appState.voiceOn ? Icons.volume_up : Icons.volume_off,
                      color: appState.voiceOn ? QColors.muted : QColors.dim,
                      size: 19),
                ),
              ),
            ),
          ]),
          const Divider(color: QColors.rule, height: 20),
          // ticks
          // The tick strip is the only indication of how far through the round
          // you are, and it is pure colour — invisible to a screen reader and
          // to anyone who cannot tell coral from cream. One spoken value
          // carries the same information.
          Semantics(
            label: Strings.t(locale, 'a11yQuestionOf'),
            value: '${c.index + 1} / ${c.total}',
            child: ExcludeSemantics(
              child: Row(
                children: List.generate(c.total, (i) {
                  final col = i < c.index
                      ? QColors.coral
                      : (i == c.index ? QColors.cream : const Color(0x22FFFFFF));
                  return Expanded(
                    child: Container(
                        height: 2,
                        margin:
                            EdgeInsets.only(right: i == c.total - 1 ? 0 : 4),
                        color: col),
                  );
                }),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // timer or review label
          if (c.timed)
            // Listens to the countdown directly rather than to the controller,
            // so a 16ms tick repaints two pixels of bar instead of rebuilding
            // the whole question screen sixty times a second.
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: ValueListenableBuilder<double>(
                valueListenable: c.remaining,
                builder: (_, __, ___) {
                  final p = c.progress;
                  return Semantics(
                    // Announced in whole seconds rather than as a percentage,
                    // and NOT as a live region: re-announcing every 16ms tick
                    // would talk over the question itself. A screen-reader user
                    // can query it whenever they want to know.
                    label: Strings.t(locale, 'a11yTimeLeft'),
                    value: '${(c.remainingMs / 1000).ceil()}',
                    child: ExcludeSemantics(
                      child: LinearProgressIndicator(
                        value: p,
                        minHeight: 2,
                        backgroundColor: const Color(0x1FFFFFFF),
                        valueColor: AlwaysStoppedAnimation<Color>(
                            p <= 0.375 ? QColors.amber : QColors.coral),
                      ),
                    ),
                  );
                },
              ),
            )
          else
            Row(children: [
              const Icon(Icons.school_outlined, size: 13, color: QColors.coral),
              const SizedBox(width: 6),
              Text(Strings.t(locale, 'review'),
                  style: QType.mono(size: 11, color: QColors.coral, spacing: 1.5)),
            ]),
          // Everything between the timer and the Next button scrolls. The
          // "Explain this word" panel expands inline on tap; inside a plain
          // Column the two Spacers just collapsed and then the Next button was
          // pushed off the bottom of the screen with no way to reach it, which
          // left the round unfinishable. A min-height of the viewport keeps the
          // original spread-out layout while the content fits, and starts
          // scrolling only once it doesn't.
          //
          // THE ALIGN IS LOAD-BEARING, and it replaced an IntrinsicHeight
          // wrapped around a Column with `Spacer()` above and `Spacer(flex: 2)`
          // below. That construction was broken: IntrinsicHeight has to measure
          // its child, the child contains HeroWord, and HeroWord is a
          // LayoutBuilder, which cannot answer an intrinsic query. In debug it
          // threw "LayoutBuilder does not support returning intrinsic
          // dimensions" and the question was replaced by the error panel; in
          // release the assert is compiled out and LayoutBuilder silently
          // reports an intrinsic height of zero, so the spread was simply
          // wrong. game_a11y_test.dart is what surfaced it.
          //
          // Align needs no intrinsics: given a minHeight it fills, given a
          // taller child it grows, and the -0.34 y reproduces the 1 : 2 split
          // the two Spacers used to give.
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Align(
                    alignment: const Alignment(0, -0.34),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                      // meta
                      Row(children: [
                        _DiffTag(difficulty: w.difficulty),
                        const SizedBox(width: 12),
                        Text(w.pos.toUpperCase(), style: QType.mono(size: 11, color: QColors.muted, spacing: 2)),
                        if (locale != 'en' && !c.isSpelling) ...[
                          const SizedBox(width: 12),
                          _LangFlow(locale: locale, reverse: c.isReverse),
                        ],
                      ]),
                      const SizedBox(height: 8),
                      Text(Strings.t(locale, _askKey(c)).toUpperCase(),
                          style: QType.mono(size: 11.5, color: QColors.muted, spacing: 3)),
                      const SizedBox(height: 8),
                      _prompt(c, w, g, locale, revealed),
                      const SizedBox(height: 22),
                      if (c.isSpelling)
                        _SpellInput(
                          controller: _spellCtrl,
                          enabled: !revealed,
                          locale: locale,
                          onSubmit: (text) {
                            if (text.trim().isEmpty) return;
                            c.choose(text);
                          },
                        )
                      else
                        for (final opt in c.currentOptions)
                          _Option(
                            // Keyed so game_a11y_test.dart can tap a specific
                            // answer without knowing what the round dealt.
                            key: ValueKey(
                                'opt-${c.currentOptions.indexOf(opt)}'),
                            label: opt,
                            index: c.currentOptions.indexOf(opt),
                            state: _stateFor(opt, c.correctAnswer, revealed, c.chosen),
                            onTap: revealed ? null : () => c.choose(opt),
                            locale: locale,
                          ),
                      if (revealed) ...[
                        const SizedBox(height: 8),
                        TweenAnimationBuilder<double>(
                          key: ValueKey(c.index),
                          tween: Tween(begin: 0.0, end: 1.0),
                          duration: A11y.duration(
                              context, const Duration(milliseconds: 260)),
                          curve: Curves.easeOut,
                          builder: (_, t, child) => Opacity(
                            opacity: t.clamp(0.0, 1.0),
                            child: Transform.translate(offset: Offset(0, (1 - t) * 8), child: child),
                          ),
                          // The verdict panel appears after the answer lands,
                          // so it is the one thing on this screen that should
                          // interrupt: a live region makes a screen reader
                          // announce it without the user going looking.
                          child: Semantics(
                            liveRegion: true,
                            child: _Reveal(c: c, g: g, locale: locale),
                          ),
                        ),
                      ],
                      if (revealed && !c.currentKnown) ...[
                        const SizedBox(height: 8),
                        Center(
                          child: TextButton.icon(
                            onPressed: () {
                              c.markCurrentKnown();
                              c.next();
                            },
                            icon: const Icon(Icons.check_circle_outline,
                                size: 15, color: QColors.dim),
                            label: Text(Strings.t(locale, 'knowIt').toUpperCase(),
                                style: QType.mono(size: 11, color: QColors.muted, spacing: 1)),
                          ),
                        ),
                      ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _CoralBtn(
            label: c.isLast ? Strings.t(locale, 'seeResults') : Strings.t(locale, 'next'),
            enabled: revealed,
            onPressed: revealed ? c.next : null,
          ),
        ],
      ),
      ),
    );
  }

  Widget _stat(String v, Color dot) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: dot)),
        const SizedBox(width: 5),
        Text(v, style: QType.mono(size: 12, color: QColors.ink)),
      ]);

  _OptState _stateFor(String opt, String correct, bool revealed, String? chosen) {
    if (!revealed) return _OptState.idle;
    if (opt == correct) return _OptState.correct;
    if (opt == chosen) return _OptState.wrong;
    return _OptState.dim;
  }

  String _askKey(GameController c) {
    if (c.isReverse) return 'whichWord';
    if (c.isListen) return 'listenPrompt';
    if (c.isSpelling) return 'spellPrompt';
    return 'ask';
  }

  Widget _prompt(GameController c, Word w, Gloss g, String locale, bool revealed) {
    // Reverse: show the definition (the answer is the word).
    if (c.isReverse) {
      return Text(g.correct,
          style: QType.serif(size: 30, color: QColors.cream, height: 1.15));
    }
    // Listen / Spelling (before reveal): hide the word behind a tap-to-hear
    // speaker — but only when voice is on, or the round would be unplayable.
    if ((c.isListen || c.isSpelling) && !revealed && appState.voiceOn) {
      return GestureDetector(
        onTap: () => Voice.instance.speak(w.word,
            langCode: w.lang, headword: w.word, headwordPos: w.pos, sayAs: w.say),
        child: Row(children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: QColors.coral.withOpacity(0.12),
              border: Border.all(color: QColors.coral),
            ),
            child: const Icon(Icons.volume_up, color: QColors.coral, size: 30),
          ),
          const SizedBox(width: 16),
          Text(Strings.t(locale, 'tapToHear').toUpperCase(),
              style: QType.mono(size: 12, color: QColors.muted, spacing: 2)),
        ]),
      );
    }
    // Classic (and Listen after reveal): the word + pronounce button.
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      // Scales down rather than wrapping mid-word — see HeroWord.
      Expanded(child: HeroWord(w.word)),
      const SizedBox(width: 14),
      _SayButton(word: w),
    ]);
  }
}

class _DiffTag extends StatelessWidget {
  final String difficulty;
  const _DiffTag({required this.difficulty});
  @override
  Widget build(BuildContext context) {
    final col = QColors.difficulty(difficulty);
    return Container(
      padding: const EdgeInsets.only(bottom: 3),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: col))),
      child: Text(difficulty.toUpperCase(), style: QType.mono(size: 11, color: col, spacing: 2)),
    );
  }
}

/// Small "which language is which" tag shown during play whenever the answer
/// language differs from English — the direct fix for the confusion where a
/// user sees an English word with, say, Spanish answer options and assumes
/// something's broken. Classic/Listen: word is EN, answers are in [locale].
/// Reverse: the definition is in [locale], the answer options are EN words.
class _LangFlow extends StatelessWidget {
  final String locale;
  final bool reverse;
  const _LangFlow({required this.locale, required this.reverse});
  @override
  Widget build(BuildContext context) {
    final tag = reverse ? '${locale.toUpperCase()} → EN' : 'EN → ${locale.toUpperCase()}';
    return Tooltip(
      message: Strings.t(locale, 'answerLangHint'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: QColors.rule),
          borderRadius: BorderRadius.circular(kQRadius),
        ),
        child: Text(tag, style: QType.mono(size: 11, color: QColors.muted, spacing: 1)),
      ),
    );
  }
}

class _SayButton extends StatelessWidget {
  final Word word;
  const _SayButton({required this.word});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Voice.instance.speak(word.word,
          langCode: word.lang,
          headword: word.word,
          headwordPos: word.pos,
          sayAs: word.say),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: QColors.coral.withOpacity(0.10),
          border: Border.all(color: QColors.coral),
        ),
        child: const Icon(Icons.volume_up, color: QColors.coral, size: 18),
      ),
    );
  }
}

enum _OptState { idle, correct, wrong, dim }

class _Option extends StatelessWidget {
  final String label;
  final int index;
  final _OptState state;
  final VoidCallback? onTap;
  final String locale;
  const _Option(
      {super.key,
      required this.label,
      required this.index,
      required this.state,
      required this.onTap,
      required this.locale});

  @override
  Widget build(BuildContext context) {
    Color border = QColors.rule;
    Color bg = QColors.panel;
    double opacity = 1;
    Color keyColor = QColors.dim;
    switch (state) {
      case _OptState.correct:
        border = QColors.coral;
        bg = QColors.coral.withOpacity(0.12);
        keyColor = QColors.coral;
        break;
      case _OptState.wrong:
        border = QColors.amber;
        bg = QColors.amber.withOpacity(0.10);
        keyColor = QColors.amber;
        break;
      case _OptState.dim:
        opacity = 0.4;
        break;
      case _OptState.idle:
        break;
    }
    const keys = ['A', 'B', 'C'];

    // After the reveal, right and wrong are signalled by border colour alone —
    // coral against amber, which is the single worst pair in the palette for a
    // red-green colour deficiency, and invisible to a screen reader entirely.
    // The verdict goes into the semantic label so words carry it too.
    final verdict = switch (state) {
      _OptState.correct => Strings.t(locale, 'a11yCorrect'),
      _OptState.wrong => Strings.t(locale, 'a11yWrong'),
      _ => null,
    };

    return Semantics(
      button: true,
      enabled: onTap != null,
      label: verdict == null ? label : '$label, $verdict',
      onTap: onTap,
      child: ExcludeSemantics(
        child: Opacity(
          opacity: opacity,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              borderRadius: BorderRadius.circular(kQRadius),
              onTap: onTap,
              child: Container(
                // A tappable answer must clear the 44pt minimum target on both
                // platforms, and must grow when the type does — a 16pt answer
                // at 2x text is 32pt and used to spill out of a fixed box.
                constraints: BoxConstraints(minHeight: A11y.scale(context, 52)),
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: bg,
                  border: Border.all(color: border),
                  borderRadius: BorderRadius.circular(kQRadius),
                ),
                child: Row(children: [
                  Text(index >= 0 && index < 3 ? keys[index] : '?',
                      style: QType.mono(size: 12, color: keyColor, spacing: 1)),
                  const SizedBox(width: 14),
                  Expanded(child: Text(label, style: QType.sans(size: 16))),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Free-text answer field for Spelling mode — the one non-multiple-choice
/// interaction in the game, so it gets its own input instead of [_Option].
class _SpellInput extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final String locale;
  final ValueChanged<String> onSubmit;
  const _SpellInput({
    required this.controller,
    required this.enabled,
    required this.locale,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: controller,
        enabled: enabled,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.done,
        style: QType.sans(size: 18, color: QColors.cream),
        cursorColor: QColors.coral,
        onSubmitted: onSubmit,
        decoration: InputDecoration(
          hintText: Strings.t(locale, 'typeTheWord'),
          hintStyle: QType.sans(size: 16, color: QColors.dim),
          filled: true,
          fillColor: QColors.panel,
          contentPadding: const EdgeInsets.all(15),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(kQRadius),
            borderSide: const BorderSide(color: QColors.rule),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(kQRadius),
            borderSide: const BorderSide(color: QColors.coral),
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(kQRadius),
            borderSide: const BorderSide(color: QColors.rule),
          ),
        ),
      ),
      if (enabled) ...[
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: QColors.rule),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kQRadius)),
            ),
            onPressed: () => onSubmit(controller.text),
            child: Text(Strings.t(locale, 'check').toUpperCase(),
                style: QType.mono(size: 12, color: QColors.ink, spacing: 2)),
          ),
        ),
      ],
    ]);
  }
}

class _Reveal extends StatelessWidget {
  final GameController c;
  final Gloss g;
  final String locale;
  const _Reveal({required this.c, required this.g, required this.locale});

  @override
  Widget build(BuildContext context) {
    final ok = c.wasCorrect;
    final to = c.timedOut;
    final verdict = ok ? Strings.t(locale, 'correct') : (to ? Strings.t(locale, 'time') : Strings.t(locale, 'notQuite'));
    return Container(
      decoration: const BoxDecoration(border: Border(left: BorderSide(color: QColors.coral, width: 2))),
      padding: const EdgeInsets.only(left: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(verdict.toUpperCase(),
            style: QType.mono(size: 11, color: ok ? QColors.coral : QColors.amber, spacing: 2)),
        const SizedBox(height: 6),
        Text('${c.current.word} — ${g.correct}', style: QType.serif(size: 17, color: QColors.cream)),
        if (c.isSpelling && !ok && (c.chosen ?? '').trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('${Strings.t(locale, 'youTyped')}: “${c.chosen}”',
              style: QType.sans(size: 13, color: QColors.amber)),
        ],
        const SizedBox(height: 7),
        if (g.example.isNotEmpty)
          Text('“${g.example}”', style: QType.sans(size: 13.5, color: QColors.muted, height: 1.5).copyWith(fontStyle: FontStyle.italic)),
        if ((g.example2 ?? '').isNotEmpty) ...[
          const SizedBox(height: 5),
          Text('“${g.example2}”', style: QType.sans(size: 13.5, color: QColors.muted, height: 1.5).copyWith(fontStyle: FontStyle.italic)),
        ],
        const SizedBox(height: 6),
        Row(children: [
          if (c.currentFlagged)
            Text(Strings.t(locale, 'reported').toUpperCase(),
                style: QType.mono(size: 11, color: QColors.muted, spacing: 1))
          else
            TextButton.icon(
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () {
                c.flagCurrent();
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(Strings.t(locale, 'reportThanks'),
                      style: QType.mono(size: 12, color: QColors.cream)),
                  backgroundColor: const Color(0xFF14141A),
                  duration: const Duration(seconds: 2),
                ));
              },
              icon: const Icon(Icons.flag_outlined, size: 13, color: QColors.dim),
              label: Text(Strings.t(locale, 'reportItem').toUpperCase(),
                  style: QType.mono(size: 11, color: QColors.muted, spacing: 1)),
            ),
          const Spacer(),
          TextButton.icon(
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () => Navigator.of(context).push(PageRouteBuilder(
              opaque: true,
              transitionDuration: A11y.duration(context, const Duration(milliseconds: 240)),
              pageBuilder: (_, __, ___) => PronounceScreen(word: c.current),
              transitionsBuilder: (_, anim, __, child) =>
                  FadeTransition(opacity: anim, child: child),
            )),
            icon: const Icon(Icons.mic_none, size: 14, color: QColors.coral),
            label: Text(Strings.t(locale, 'practiceSay').toUpperCase(),
                style: QType.mono(size: 11, color: QColors.coral, spacing: 1)),
          ),
        ]),
        _ExplainButton(word: c.current, g: g, locale: locale),
      ]),
    );
  }
}

/// Bounded "explain this word" AI helper — a single tap fetches one short
/// explanation + a fresh example via [Tutor], shown inline. Not a chat: no
/// follow-up input, no conversation state, so the cost stays capped per
/// word rather than growing with how much a user types.
class _ExplainButton extends StatefulWidget {
  final Word word;
  final Gloss g;
  final String locale;
  const _ExplainButton({required this.word, required this.g, required this.locale});

  @override
  State<_ExplainButton> createState() => _ExplainButtonState();
}

class _ExplainButtonState extends State<_ExplainButton> {
  WordExplanation? _result;
  bool _loading = false;
  bool _failed = false;

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final r = await Tutor.instance.explain(
      wordId: widget.word.id,
      word: widget.word.word,
      definition: widget.g.correct,
      lang: widget.locale,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _result = r;
      _failed = r == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final locale = widget.locale;
    if (_result != null) {
      return Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: QColors.panel,
          border: Border.all(color: QColors.rule),
          borderRadius: BorderRadius.circular(kQRadius),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.auto_awesome, size: 13, color: QColors.coral),
            const SizedBox(width: 6),
            Text(Strings.t(locale, 'explainThis').toUpperCase(),
                style: QType.mono(size: 10, color: QColors.coral, spacing: 1.2)),
          ]),
          const SizedBox(height: 6),
          Text(_result!.explanation,
              style: QType.sans(size: 13, color: QColors.ink, height: 1.4)),
          const SizedBox(height: 6),
          Text('“${_result!.example}”',
              style: QType.sans(size: 12.5, color: QColors.muted, height: 1.4)
                  .copyWith(fontStyle: FontStyle.italic)),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: TextButton.icon(
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(0, 28),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: _loading ? null : _fetch,
        icon: _loading
            ? const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2, color: QColors.coral))
            : Icon(_failed ? Icons.refresh : Icons.auto_awesome, size: 14, color: QColors.coral),
        label: Text(
            Strings.t(locale, _loading ? 'explainLoading' : (_failed ? 'explainRetry' : 'explainThis'))
                .toUpperCase(),
            style: QType.mono(size: 11, color: QColors.coral, spacing: 1)),
      ),
    );
  }
}

class _ResultView extends StatelessWidget {
  final GameController c;
  final VoidCallback onPlayAgain;
  final VoidCallback onChangePath;
  const _ResultView({required this.c, required this.onPlayAgain, required this.onChangePath});

  @override
  Widget build(BuildContext context) {
    final locale = c.locale;
    final acc = c.accuracy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 30, 24, 24),
      child: Column(children: [
        const Spacer(),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: QColors.panel,
            border: const Border(top: BorderSide(color: QColors.coral, width: 2)),
          ),
          child: Column(children: [
            Text(Strings.t(locale, 'estRank').toUpperCase(),
                textAlign: TextAlign.center,
                style: QType.mono(size: 11, color: QColors.muted, spacing: 3)),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: c.vocabRank.toDouble()),
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeOutCubic,
              builder: (_, v, __) =>
                  Text('${v.round()}', style: QType.serif(size: 52, color: QColors.coral)),
            ),
            Text(Strings.t(locale, 'wordsYouKnow'),
                style: QType.mono(size: 11, color: QColors.muted, spacing: 1)),
            const SizedBox(height: 16),
            const Divider(color: QColors.rule, height: 1),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              _rstat('${c.correctCount}/${c.total}', Strings.t(locale, 'correct')),
              _rstat('$acc%', Strings.t(locale, 'accuracy')),
              _rstat('${c.bestStreak}', Strings.t(locale, 'bestRun')),
            ]),
          ]),
        ),
        const Spacer(),
        _CoralBtn(label: Strings.t(locale, 'playAgain'), enabled: true, onPressed: onPlayAgain),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: QColors.rule),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kQRadius)),
            ),
            onPressed: onChangePath,
            child: Text(Strings.t(locale, 'changePath').toUpperCase(),
                style: QType.mono(size: 12, color: QColors.ink, spacing: 2)),
          ),
        ),
        const SizedBox(height: 4),
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(
                text:
                    'Qulex · CodeAscent — I know ~${c.vocabRank} words 🧠 (${c.correctCount}/${c.total} this round)'));
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(Strings.t(locale, 'copied'),
                  style: QType.mono(size: 12, color: QColors.cream)),
              backgroundColor: const Color(0xFF14141A),
              duration: const Duration(seconds: 2),
            ));
          },
          icon: const Icon(Icons.ios_share, size: 15, color: QColors.muted),
          label: Text(Strings.t(locale, 'share').toUpperCase(),
              style: QType.mono(size: 11, color: QColors.muted, spacing: 2)),
        ),
      ]),
    );
  }

  Widget _rstat(String n, String l) => Column(children: [
        Text(n, style: QType.serif(size: 24, color: QColors.cream)),
        const SizedBox(height: 2),
        Text(l.toUpperCase(), style: QType.mono(size: 10.5, color: QColors.muted, spacing: 1.5)),
      ]);
}

class _CoralBtn extends StatelessWidget {
  final String label;
  final bool enabled;
  final VoidCallback? onPressed;
  const _CoralBtn({required this.label, required this.enabled, required this.onPressed});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: enabled ? QColors.coral : QColors.panel,
          foregroundColor: enabled ? const Color(0xFF160603) : QColors.dim,
          disabledBackgroundColor: QColors.panel,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kQRadius)),
        ),
        onPressed: onPressed,
        child: Text(label.toUpperCase(),
            style: QType.mono(size: 13, color: enabled ? const Color(0xFF160603) : QColors.dim, spacing: 2)),
      ),
    );
  }
}

/// A dark radial scrim painted over the shared animated backdrop, focusing
/// attention on the word/options during play.
class _GameScrim extends StatelessWidget {
  const _GameScrim();
  @override
  Widget build(BuildContext context) {
    return const Positioned.fill(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.2),
              radius: 1.1,
              colors: [Color(0x5907070A), Color(0xD107070A)],
              stops: [0, 0.95],
            ),
          ),
        ),
      ),
    );
  }
}


/// Shown when no round could be dealt.
///
/// Reached when a track has nothing that matches the learner's difficulty (the
/// GRE track with difficulty set to Easy is the clean case — no GRE-tagged word
/// in the catalogue is easy), or when every word they have met is marked known.
/// Both used to throw a RangeError out of initState and land on the generic
/// error panel, which told the learner nothing and offered them nothing.
class _EmptyDeckView extends StatelessWidget {
  final String locale;
  final bool canResurface;
  final Future<void> Function() onResurface;
  final VoidCallback onChangePath;

  const _EmptyDeckView({
    required this.locale,
    required this.canResurface,
    required this.onResurface,
    required this.onChangePath,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            IconButton(
              onPressed: onChangePath,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              icon: const Icon(Icons.arrow_back, color: QColors.muted, size: 19),
            ),
            const SizedBox(width: 4),
            const Wordmark(size: 19),
          ]),
          const Spacer(),
          const Icon(Icons.inbox_outlined, size: 34, color: QColors.coral),
          const SizedBox(height: 18),
          Text(Strings.t(locale, 'noWordsTitle'),
              style: QType.serif(
                  size: 26, color: QColors.cream, height: 1.15)),
          const SizedBox(height: 10),
          Text(Strings.t(locale, 'noWordsBody'),
              style: QType.sans(size: 14, color: QColors.muted, height: 1.45)),
          const Spacer(flex: 2),
          if (canResurface) ...[
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: QColors.coral,
                  foregroundColor: const Color(0xFF160603),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(kQRadius)),
                ),
                onPressed: () => onResurface(),
                child: Text(Strings.t(locale, 'noWordsResurface'),
                    style: QType.mono(
                        size: 12, color: const Color(0xFF160603), spacing: 1.6)),
              ),
            ),
            const SizedBox(height: 10),
          ],
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: QColors.rule),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(kQRadius)),
              ),
              onPressed: onChangePath,
              child: Text(Strings.t(locale, 'noWordsCta'),
                  style: QType.mono(
                      size: 12, color: QColors.ink, spacing: 1.6)),
            ),
          ),
        ],
      ),
    );
  }
}
