import 'package:flutter/material.dart';

import '../data/progress_store.dart';
import '../l10n/strings.dart';
import '../models/word.dart';
import '../services/voice.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import '../widgets/wordmark.dart';

/// A ~10-question adaptive placement quiz. It binary-searches over word
/// frequency: a correct answer raises the floor, a miss lowers the ceiling, so
/// it converges on the frequency rank the learner reliably knows. The result
/// biases which NEW words the app introduces next.
class PlacementScreen extends StatefulWidget {
  final List<Word> words;
  final ProgressStore store;
  const PlacementScreen({super.key, required this.words, required this.store});

  @override
  State<PlacementScreen> createState() => _PlacementScreenState();
}

class _PlacementScreenState extends State<PlacementScreen> {
  // Six, not ten. A binary search over frequency rank still narrows to one of
  // 64 buckets in six steps, which is finer than the difficulty bands we
  // actually act on — and the completion rate of a first-run quiz matters more
  // here than the last bit of precision. Placement is the gate on level
  // matching and on Listen/Spelling, so a learner abandoning it halfway is the
  // expensive outcome.
  static const int _questions = 6;
  static const int _minRank = 1500;
  static const int _maxRank = 9000;

  late final List<Word> _pool;
  final Set<String> _used = {};
  int _lo = _minRank;
  int _hi = _maxRank;
  int _target = (_minRank + _maxRank) ~/ 2;
  int _qIndex = 0;

  Word? _current;
  List<String> _options = const [];
  String? _selected;
  bool _answered = false;
  bool _finished = false;
  int _resultRank = 0;

  @override
  void initState() {
    super.initState();
    // Only words that have a gloss in the active locale make clean questions.
    final loc = appState.locale;
    _pool = widget.words.where((w) => w.hasGloss(loc) || w.hasGloss('en')).toList()
      ..sort((a, b) => a.freqRank.compareTo(b.freqRank));
    _pickWord();
  }

  void _pickWord() {
    Word? best;
    int bestDist = 1 << 30;
    for (final w in _pool) {
      if (_used.contains(w.id)) continue;
      final d = (w.freqRank - _target).abs();
      if (d < bestDist) {
        bestDist = d;
        best = w;
      }
    }
    if (best == null) {
      _finish();
      return;
    }
    _used.add(best.id);
    _current = best;
    _options = best.glossFor(appState.locale).shuffledOptions();
    _selected = null;
    _answered = false;
    if (appState.voiceOn) {
      Voice.instance.speak(best.word,
          langCode: best.lang,
          headword: best.word,
          headwordPos: best.pos,
          sayAs: best.say);
    }
  }

  void _choose(String opt) {
    if (_answered) return;
    final correct = opt == _current!.glossFor(appState.locale).correct;
    setState(() {
      _selected = opt;
      _answered = true;
      if (correct) {
        _lo = _target; // knows this level → raise floor
      } else {
        _hi = _target; // missed → lower ceiling
      }
    });
    Future.delayed(const Duration(milliseconds: 650), () {
      if (!mounted) return;
      _qIndex++;
      if (_qIndex >= _questions) {
        _finish();
      } else {
        setState(() {
          _target = (_lo + _hi) ~/ 2;
          _pickWord();
        });
      }
    });
  }

  Future<void> _finish() async {
    _resultRank = _lo.clamp(_minRank, _maxRank);
    await widget.store.savePlacement(_resultRank);
    if (mounted) setState(() => _finished = true);
  }

  String _tierKey(int rank) {
    if (rank < 3200) return 'lvlBeginner';
    if (rank < 5000) return 'lvlIntermediate';
    if (rank < 6800) return 'lvlAdvanced';
    return 'lvlExpert';
  }

  @override
  Widget build(BuildContext context) {
    final locale = appState.locale;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 26),
          child: (_finished || _current == null)
              ? _result(locale)
              : _question(locale),
        ),
      ),
    );
  }

  Widget _question(String locale) {
    final w = _current!;
    final correct = w.glossFor(locale).correct;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Wordmark(size: 22),
          const SizedBox(width: 9),
          Text(Strings.t(locale, 'placement').toUpperCase(),
              style: QType.mono(size: 14, color: QColors.coral, spacing: 3)),
          const Spacer(),
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close, color: QColors.muted),
          ),
        ]),
        const SizedBox(height: 8),
        // progress bar
        Row(children: [
          for (var i = 0; i < _questions; i++) ...[
            Expanded(
              child: Container(
                height: 3,
                decoration: BoxDecoration(
                  color: i <= _qIndex ? QColors.coral : QColors.rule,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            if (i < _questions - 1) const SizedBox(width: 4),
          ],
        ]),
        const Spacer(flex: 2),
        Text(Strings.t(locale, 'placementPrompt').toUpperCase(),
            style: QType.mono(size: 11, color: QColors.muted, spacing: 3)),
        const SizedBox(height: 12),
        HeroWord(w.word, maxSize: 40),
        const Spacer(flex: 1),
        for (final opt in _options)
          _POpt(
            label: opt,
            answered: _answered,
            isCorrect: opt == correct,
            isChosen: opt == _selected,
            onTap: () => _choose(opt),
          ),
        const Spacer(flex: 2),
      ],
    );
  }

  Widget _result(String locale) {
    final tier = Strings.t(locale, _tierKey(_resultRank));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Wordmark(size: 22),
          const SizedBox(width: 9),
          Text(Strings.t(locale, 'placement').toUpperCase(),
              style: QType.mono(size: 14, color: QColors.coral, spacing: 3)),
        ]),
        const Spacer(flex: 2),
        Icon(Icons.explore_outlined, color: QColors.coral, size: 40),
        const SizedBox(height: 18),
        Text(Strings.t(locale, 'placementResultTitle'),
            style: QType.mono(size: 11, color: QColors.muted, spacing: 3)),
        const SizedBox(height: 10),
        Text(tier,
            style: QType.serif(size: 34, color: QColors.cream, height: 1.1)),
        const SizedBox(height: 12),
        Text(Strings.t(locale, 'placementResultSub'),
            style: QType.sans(size: 14, color: QColors.muted, height: 1.5)),
        const Spacer(flex: 3),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: QColors.coral,
              foregroundColor: const Color(0xFF160603),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            onPressed: () => Navigator.of(context).maybePop(),
            child: Text(Strings.t(locale, 'startLearning').toUpperCase(),
                style: QType.mono(
                    size: 13, color: const Color(0xFF160603), spacing: 2)),
          ),
        ),
      ],
    );
  }
}

class _POpt extends StatelessWidget {
  final String label;
  final bool answered, isCorrect, isChosen;
  final VoidCallback onTap;
  const _POpt({
    required this.label,
    required this.answered,
    required this.isCorrect,
    required this.isChosen,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Color border = QColors.rule;
    Color text = QColors.cream;
    Color? fill;
    if (answered) {
      if (isCorrect) {
        border = QColors.coral;
        text = QColors.coral;
        fill = QColors.coral.withOpacity(0.1);
      } else if (isChosen) {
        border = QColors.rule;
        text = QColors.dim;
      } else {
        text = QColors.muted;
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
          decoration: BoxDecoration(
            color: fill ?? QColors.panel,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(label, style: QType.sans(size: 14, color: text)),
        ),
      ),
    );
  }
}
