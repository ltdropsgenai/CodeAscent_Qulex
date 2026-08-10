import 'package:flutter_tts/flutter_tts.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';

/// Thin wrapper around flutter_tts. Speaks the target word in its own language
/// and meanings in the user's chosen locale. No-ops when voice is muted.
class Voice {
  Voice._();
  static final Voice instance = Voice._();

  final FlutterTts _tts = FlutterTts();
  bool _init = false;

  Future<void> _ensure() async {
    if (_init) return;
    _init = true;
    try {
      await _tts.awaitSpeakCompletion(true);
      await _tts.setSpeechRate(0.42); // flutter_tts rate is slow-biased
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
    } catch (_) {}
  }

  /// Speak [text]. [langCode] is a locale key ('en'/'es'); we map to BCP-47.
  Future<void> speak(String text, {String langCode = 'en'}) async {
    if (!appState.voiceOn) return;
    await _ensure();
    try {
      await _tts.stop();
      await _tts.setLanguage(Strings.ttsLang[langCode] ?? 'en-US');
      await _tts.speak(text);
    } catch (_) {
      // TTS unavailable on this platform/voice — fail silently.
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
