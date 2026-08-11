import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'heteronyms.dart';
import 'supabase_config.dart';

/// Speaks words and definitions with ElevenLabs' natural voices, proxied
/// through a Supabase Edge Function (`tts`) so the API key never ships in the
/// app and every generated clip is cached server-side — the same text+
/// language is only ever synthesized once, for any user. Clips are cached
/// again on-device after first fetch so replays are instant and work
/// offline. If ElevenLabs/Supabase is unreachable for any reason (offline,
/// function down, not configured), we fall back to the device's built-in
/// voice (flutter_tts) so playback never goes silent — degraded, not broken.
class Voice {
  Voice._();
  static final Voice instance = Voice._();

  final FlutterTts _fallbackTts = FlutterTts();
  final AudioPlayer _player = AudioPlayer();
  bool _fallbackInit = false;
  Directory? _cacheDir;

  Future<void> _ensureFallback() async {
    if (_fallbackInit) return;
    _fallbackInit = true;
    try {
      await _fallbackTts.awaitSpeakCompletion(true);
      await _fallbackTts.setSpeechRate(0.42); // flutter_tts rate is slow-biased
      await _fallbackTts.setPitch(1.0);
      await _fallbackTts.setVolume(1.0);
    } catch (_) {}
  }

  Future<Directory> _ensureCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/qbit_tts_cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _cacheDir = dir;
  }

  // djb2 — fast, deterministic, plenty for a local filename (not security-sensitive).
  String _hash(String s) {
    var h = 5381;
    for (final code in s.codeUnits) {
      h = ((h << 5) + h + code) & 0x7fffffff;
    }
    return h.toRadixString(16);
  }

  /// Speak [text]. [langCode] is a locale key ('en'/'es'/...); for
  /// [Strings.ttsLang]-mapped fallback voices. Pass [headword]/[headwordPos]
  /// when [text] IS (or contains) a catalogued word's own headword — its
  /// `pos` disambiguates heteronyms (see heteronyms.dart) for both the
  /// standalone word and full-sentence definitions/examples.
  Future<void> speak(
    String text, {
    String langCode = 'en',
    String? headword,
    String? headwordPos,
  }) async {
    if (!appState.voiceOn) return;
    await _player.stop();
    await _fallbackTts.stop();

    final spoken = ttsRespell(text, headword: headword, headwordPos: headwordPos);
    if (await _speakViaElevenLabs(spoken, langCode)) return;
    await _speakViaFallback(spoken, langCode);
  }

  Future<bool> _speakViaElevenLabs(String text, String langCode) async {
    if (!SupabaseConfig.isConfigured) return false;
    try {
      final localPath = await _localCachePath(text, langCode);
      final localFile = File(localPath);
      if (await localFile.exists()) {
        await _player.play(DeviceFileSource(localPath));
        return true;
      }

      final res = await Supabase.instance.client.functions.invoke(
        'tts',
        body: {'text': text, 'lang': langCode},
      );
      final data = res.data;
      final url = (data is Map) ? data['url'] as String? : null;
      if (url == null) return false;

      final bytes = await _download(url);
      if (bytes == null) return false;
      await localFile.writeAsBytes(bytes, flush: true);
      await _player.play(DeviceFileSource(localPath));
      return true;
    } catch (_) {
      return false; // any failure — network, function error, decode — falls back
    }
  }

  Future<Uint8List?> _download(String url) async {
    try {
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        client.close(force: true);
        return null;
      }
      final bytes = await resp.fold<List<int>>(
          <int>[], (acc, chunk) => acc..addAll(chunk));
      client.close();
      return Uint8List.fromList(bytes);
    } catch (_) {
      return null;
    }
  }

  Future<String> _localCachePath(String text, String langCode) async {
    final dir = await _ensureCacheDir();
    final key = _hash('$langCode|$text');
    return '${dir.path}/$key.mp3';
  }

  Future<void> _speakViaFallback(String text, String langCode) async {
    await _ensureFallback();
    try {
      await _fallbackTts.setLanguage(Strings.ttsLang[langCode] ?? 'en-US');
      await _fallbackTts.speak(text);
    } catch (_) {
      // TTS unavailable on this platform/voice — fail silently.
    }
  }

  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
    try {
      await _fallbackTts.stop();
    } catch (_) {}
  }
}
