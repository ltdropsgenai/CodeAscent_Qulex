import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../l10n/strings.dart';
import '../models/word.dart';
import '../services/voice.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/wordmark.dart';

/// Pronunciation practice: hear the word, say it, get scored by on-device
/// speech recognition. Degrades gracefully where speech isn't available
/// (e.g. some web/desktop targets) by showing a friendly notice.
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
  String _heard = '';
  int _score = -1; // -1 none, 0 miss, 1 close, 2 great

  @override
  void initState() {
    super.initState();
    // Speak the target once so the learner has a model to imitate.
    if (appState.voiceOn) {
      Voice.instance.speak(widget.word.word,
          langCode: widget.word.lang,
          headword: widget.word.word,
          headwordPos: widget.word.pos,
          sayAs: widget.word.say);
    }
    _init();
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
            _score = _grade(_heard, widget.word.word);
            _listening = false;
          }
        });
      },
      localeId: Strings.ttsLang[widget.word.lang] ?? 'en-US',
      listenFor: const Duration(seconds: 5),
      pauseFor: const Duration(seconds: 3),
    );
  }

  int _grade(String heard, String target) {
    String norm(String s) =>
        s.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
    final h = norm(heard);
    final t = norm(target);
    if (h.isEmpty || t.isEmpty) return 0;
    if (h == t || h.contains(t)) return 2;
    final d = _lev(h, t);
    if (d <= 2) return 1;
    return 0;
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Wordmark(size: 22),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(Strings.t(locale, 'practiceSay').toUpperCase(),
                      style:
                          QType.mono(size: 14, color: QColors.coral, spacing: 3)),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close, color: QColors.muted),
                ),
              ]),
              const Spacer(flex: 2),
              Row(children: [
                Flexible(
                  child: Text(w.word,
                      style: QType.serif(size: 44, color: QColors.cream)),
                ),
                const SizedBox(width: 14),
                GestureDetector(
                  onTap: () =>
                      Voice.instance.speak(w.word,
                          langCode: w.lang,
                          headword: w.word,
                          headwordPos: w.pos,
                          sayAs: w.say),
                  child: const Icon(Icons.volume_up, color: QColors.coral, size: 26),
                ),
              ]),
              const SizedBox(height: 10),
              Text(w.glossFor(locale).correct,
                  style: QType.sans(size: 14, color: QColors.muted, height: 1.4)),
              const Spacer(flex: 2),
              if (_unsupported)
                Text(Strings.t(locale, 'pronounceUnsupported'),
                    style:
                        QType.sans(size: 13.5, color: QColors.dim, height: 1.5))
              else ...[
                Center(child: _verdict(locale)),
                const SizedBox(height: 20),
                Center(child: _micButton(locale)),
                const SizedBox(height: 14),
                Center(
                  child: Text(
                      _listening
                          ? Strings.t(locale, 'listening')
                          : Strings.t(locale, 'tapToSpeak'),
                      style:
                          QType.mono(size: 11, color: QColors.dim, spacing: 2)),
                ),
              ],
              const Spacer(flex: 3),
            ],
          ),
        ),
      ),
    );
  }

  Widget _verdict(String locale) {
    if (_score < 0) {
      return Text(_heard.isEmpty ? '' : '“$_heard”',
          style: QType.sans(size: 15, color: QColors.muted));
    }
    final key = _score == 2 ? 'sayGreat' : (_score == 1 ? 'sayClose' : 'sayMiss');
    final color = _score == 2 ? QColors.coral : (_score == 1 ? QColors.amber : QColors.muted);
    return Column(children: [
      Text(Strings.t(locale, key),
          style: QType.serif(size: 24, color: color)),
      if (_heard.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text('${Strings.t(locale, 'heard')}: “$_heard”',
            style: QType.mono(size: 10.5, color: QColors.dim, spacing: 0.5)),
      ],
    ]);
  }

  Widget _micButton(String locale) {
    return GestureDetector(
      onTap: _toggle,
      child: Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _listening
              ? QColors.coral
              : QColors.coral.withOpacity(0.12),
          border: Border.all(color: QColors.coral, width: 2),
        ),
        child: Icon(_listening ? Icons.stop : Icons.mic,
            color: _listening ? const Color(0xFF160603) : QColors.coral,
            size: 34),
      ),
    );
  }
}
