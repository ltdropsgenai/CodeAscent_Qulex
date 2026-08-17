import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../l10n/strings.dart';
import '../models/word.dart';
import '../services/heteronyms.dart';
import '../services/voice.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/wordmark.dart';

/// Pronunciation practice: hear the target, say it back, get scored by
/// on-device speech recognition. Degrades gracefully where speech isn't
/// available (some web/desktop targets) by showing a friendly notice.
///
/// Two modes:
///  - SENTENCE (default where possible) — the learner says the word inside its
///    example sentence. Recognizers are markedly more reliable given several
///    words of context than on a single token, and saying a word in a sentence
///    is closer to the thing we actually want to teach. The carrier is always
///    the ENGLISH example, because headwords are always English; the localized
///    examples are translations and don't contain the target word.
///  - WORD ONLY — the fallback, and the only option for the ~6% of entries
///    whose example uses an inflected form ("held" for "hold") rather than the
///    headword itself.
///
/// Honesty about heteronyms: speech recognition hands back spelling, not
/// sound, so both readings of "wind" arrive as the same transcript. For those
/// words we can confirm the learner was understood but NOT that they chose the
/// right reading — so we say that plainly instead of awarding a score the
/// check cannot support.
class PronounceScreen extends StatefulWidget {
  final Word word;
  const PronounceScreen({super.key, required this.word});

  @override
  State<PronounceScreen> createState() => _PronounceScreenState();
}

class _PronounceScreenState extends State<PronounceScreen> {
  final SpeechToText _stt = SpeechToText();
  bool _ready = false;
  bool _unsupported = false;
  bool _listening = false;
  bool _sentenceMode = false;
  String _heard = '';
  int _score = -1; // -1 none, 0 miss, 1 close, 2 great

  /// The English example sentence, used only when it contains the headword as
  /// a whole word — otherwise there is nothing meaningful to check against.
  String get _carrier {
    final ex = widget.word.glossFor('en').example.trim();
    if (ex.isEmpty) return '';
    final re = RegExp(r'\b' + RegExp.escape(widget.word.word) + r'\b',
        caseSensitive: false);
    return re.hasMatch(ex) ? ex : '';
  }

  bool get _canUseSentence => _carrier.isNotEmpty;

  /// True where a score would overclaim: the transcript cannot distinguish the
  /// readings, so "Nailed it" would be a lie.
  bool get _unverifiable =>
      isHeteronym(widget.word.word) || (widget.word.say?.isNotEmpty ?? false);

  String get _prompt => _sentenceMode ? _carrier : widget.word.word;

  @override
  void initState() {
    super.initState();
    _sentenceMode = _canUseSentence;
    _speakPrompt();
    _init();
  }

  void _speakPrompt() {
    if (!appState.voiceOn) return;
    Voice.instance.speak(_prompt,
        langCode: widget.word.lang,
        headword: widget.word.word,
        headwordPos: widget.word.pos,
        sayAs: widget.word.say);
  }

  Future<void> _init() async {
    try {
      _ready = await _stt.initialize(
        onStatus: (s) {
          if ((s == 'done' || s == 'notListening') && mounted) {
            setState(() => _listening = false);
          }
        },
        onError: (_) {
          if (mounted) setState(() => _listening = false);
        },
      );
    } catch (_) {
      _ready = false;
    }
    if (!_ready && mounted) setState(() => _unsupported = true);
  }

  @override
  void dispose() {
    _stt.cancel();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_listening) {
      await _stt.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    if (!_ready) {
      await _init();
      if (!mounted) return;
      if (!_ready) {
        setState(() => _unsupported = true);
        return;
      }
    }
    setState(() {
      _heard = '';
      _score = -1;
      _listening = true;
    });
    await _stt.listen(
      onResult: (r) {
        if (!mounted) return;
        setState(() {
          _heard = r.recognizedWords;
          if (r.finalResult) {
            _score = _sentenceMode
                ? _gradeSentence(_heard, _carrier, widget.word.word)
                : _grade(_heard, widget.word.word);
            _listening = false;
          }
        });
      },
      // Headwords are always English, and so is the carrier sentence.
      localeId: 'en-US',
      listenFor: Duration(seconds: _sentenceMode ? 9 : 5),
      pauseFor: const Duration(seconds: 3),
    );
  }

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp('[^a-z ]'), '');

  static List<String> _tokens(String s) =>
      _norm(s).split(' ').where((t) => t.isNotEmpty).toList();

  int _grade(String heard, String target) {
    final h = _norm(heard).replaceAll(' ', '');
    final t = _norm(target).replaceAll(' ', '');
    if (h.isEmpty || t.isEmpty) return 0;
    if (h == t || h.contains(t)) return 2;
    return _lev(h, t) <= 2 ? 1 : 0;
  }

  /// Sentence grading has two parts: did the target word survive, and how much
  /// of the sentence came through. A learner who says only the target word gets
  /// credit for it but not full marks; one who says the sentence without the
  /// target word gets none, because the target is the point.
  int _gradeSentence(String heard, String carrier, String target) {
    final heardTokens = _tokens(heard);
    if (heardTokens.isEmpty) return 0;
    final want = _tokens(carrier);
    final t = _norm(target).trim();

    final hitTarget = heardTokens.any((tok) => tok == t || _lev(tok, t) <= 1);
    if (!hitTarget) return 0;

    final pool = List<String>.from(heardTokens);
    var matched = 0;
    for (final w in want) {
      final i = pool.indexWhere((tok) => tok == w || _lev(tok, w) <= 1);
      if (i >= 0) {
        matched++;
        pool.removeAt(i);
      }
    }
    final coverage = want.isEmpty ? 0.0 : matched / want.length;
    if (coverage >= 0.6) return 2;
    return 1;
  }

  int _lev(String a, String b) {
    final m = a.length, n = b.length;
    final prev = List<int>.generate(n + 1, (i) => i);
    final cur = List<int>.filled(n + 1, 0);
    for (var i = 1; i <= m; i++) {
      cur[0] = i;
      for (var j = 1; j <= n; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        cur[j] = [cur[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost]
            .reduce((x, y) => x < y ? x : y);
      }
      for (var j = 0; j <= n; j++) {
        prev[j] = cur[j];
      }
    }
    return prev[n];
  }

  @override
  Widget build(BuildContext context) {
    final locale = appState.locale;
    final w = widget.word;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 30),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Wordmark(size: 22),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                        Strings.t(locale,
                                _sentenceMode ? 'practiceSentence' : 'practiceSay')
                            .toUpperCase(),
                        style: QType.mono(
                            size: 14, color: QColors.coral, spacing: 3)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close, color: QColors.muted),
                  ),
                ]),
                const SizedBox(height: 30),
                Row(children: [
                  Flexible(
                    child: Text(w.word,
                        style: QType.serif(size: 44, color: QColors.cream)),
                  ),
                  const SizedBox(width: 14),
                  GestureDetector(
                    onTap: _speakPrompt,
                    child: const Icon(Icons.volume_up,
                        color: QColors.coral, size: 26),
                  ),
                ]),
                const SizedBox(height: 10),
                Text(w.glossFor(locale).correct,
                    style:
                        QType.sans(size: 14, color: QColors.muted, height: 1.4)),
                if (_sentenceMode) ...[
                  const SizedBox(height: 22),
                  _carrierLine(),
                ],
                const SizedBox(height: 26),
                if (_unsupported)
                  Text(Strings.t(locale, 'pronounceUnsupported'),
                      style:
                          QType.sans(size: 13.5, color: QColors.dim, height: 1.5))
                else ...[
                  Center(child: _verdict(locale)),
                  const SizedBox(height: 20),
                  Center(child: _micButton()),
                  const SizedBox(height: 14),
                  Center(
                    child: Text(
                        _listening
                            ? Strings.t(locale, 'listening')
                            : Strings.t(locale, 'tapToSpeak'),
                        style:
                            QType.mono(size: 11, color: QColors.dim, spacing: 2)),
                  ),
                  if (_canUseSentence) ...[
                    const SizedBox(height: 18),
                    Center(child: _modeToggle(locale)),
                  ],
                  if (_unverifiable && _score >= 0) ...[
                    const SizedBox(height: 22),
                    _caveat(locale),
                  ],
                ],
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The carrier sentence with the target word picked out, so the learner can
  /// see what they're aiming at inside the phrase.
  Widget _carrierLine() {
    final re = RegExp(r'\b' + RegExp.escape(widget.word.word) + r'\b',
        caseSensitive: false);
    final spans = <TextSpan>[];
    var last = 0;
    for (final m in re.allMatches(_carrier)) {
      if (m.start > last) {
        spans.add(TextSpan(text: _carrier.substring(last, m.start)));
      }
      spans.add(TextSpan(
        text: _carrier.substring(m.start, m.end),
        style: QType.serif(size: 19, color: QColors.coral),
      ));
      last = m.end;
    }
    if (last < _carrier.length) {
      spans.add(TextSpan(text: _carrier.substring(last)));
    }
    return RichText(
      text: TextSpan(
        style: QType.serif(size: 19, color: QColors.cream),
        children: spans,
      ),
    );
  }

  Widget _modeToggle(String locale) {
    return GestureDetector(
      onTap: () {
        setState(() {
          _sentenceMode = !_sentenceMode;
          _heard = '';
          _score = -1;
        });
        _speakPrompt();
      },
      child: Text(
        Strings.t(locale, _sentenceMode ? 'practiceWordOnly' : 'practiceSentence'),
        style: QType.mono(size: 11, color: QColors.coral, spacing: 2),
      ),
    );
  }

  Widget _caveat(String locale) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: QColors.amber.withOpacity(0.45)),
      ),
      child: Text(Strings.t(locale, 'heteronymCaveat'),
          style: QType.sans(size: 12.5, color: QColors.muted, height: 1.5)),
    );
  }

  Widget _verdict(String locale) {
    if (_score < 0) {
      return Text(_heard.isEmpty ? '' : '“$_heard”',
          style: QType.sans(size: 15, color: QColors.muted));
    }
    // A correct-sounding score is withheld where the transcript cannot prove
    // the reading; the learner is told they were understood, and nothing more.
    final String key;
    final Color color;
    if (_score == 2 && _unverifiable) {
      key = 'sayRecognized';
      color = QColors.amber;
    } else if (_score == 2) {
      key = 'sayGreat';
      color = QColors.coral;
    } else if (_score == 1) {
      key = 'sayClose';
      color = QColors.amber;
    } else {
      key = 'sayMiss';
      color = QColors.muted;
    }
    return Column(children: [
      Text(Strings.t(locale, key), style: QType.serif(size: 24, color: color)),
      if (_heard.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text('${Strings.t(locale, 'heard')}: “$_heard”',
            style: QType.mono(size: 10.5, color: QColors.dim, spacing: 0.5)),
      ],
    ]);
  }

  Widget _micButton() {
    return GestureDetector(
      onTap: _toggle,
      child: Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _listening ? QColors.coral : QColors.coral.withOpacity(0.12),
          border: Border.all(color: QColors.coral, width: 2),
        ),
        child: Icon(_listening ? Icons.stop : Icons.mic,
            color: _listening ? const Color(0xFF160603) : QColors.coral,
            size: 34),
      ),
    );
  }
}
