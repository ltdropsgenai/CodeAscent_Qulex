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
/// offline. If ElevenLabs/Supabase is unreachable, slow, or not configured,
/// we fall back to the device's built-in voice (flutter_tts) so playback
/// never goes silent, or feels absent, for more than ~2.5s — degraded, not
/// broken.
class Voice {
  Voice._();
  static final Voice instance = Voice._();

  final FlutterTts _fallbackTts = FlutterTts();
  final AudioPlayer _player = AudioPlayer();
  bool _fallbackInit = false;
  Directory? _cacheDir;

  // Bumped on every speak() call. Lets a slow ElevenLabs response that
  // arrives after we've already timed-out-and-fallen-back (or after a newer
  // speak() call superseded this one) recognize it's stale and skip
  // playback — it still finishes writing to the on-device cache so the
  // *next* time this word is spoken it's instant.
  int _generation = 0;
  // The most recent generation that already spoke via the on-device
  // fallback voice — guards against a same-generation late ElevenLabs
  // response talking over/after it.
  int _fallbackGeneration = -1;

  static const _elevenLabsTimeout = Duration(milliseconds: 2500);

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
    final dir = Directory('${base.path}/qulex_tts_cache');
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
  ///
  /// Races the ElevenLabs fetch against a short timeout: if it hasn't
  /// resolved (or wasn't already cached) within [_elevenLabsTimeout], we
  /// speak immediately with the instant on-device voice instead of leaving
  /// the learner waiting in silence. The network attempt is left running in
  /// the background purely to warm the cache for next time — see
  /// [prefetch] for warming a whole deck ahead of time so this timeout is
  /// rarely hit at all.
  Future<void> speak(
    String text, {
    String langCode = 'en',
    String? headword,
    String? headwordPos,
  }) async {
    if (!appState.voiceOn) return;
    final gen = ++_generation;
    await _player.stop();
    await _fallbackTts.stop();

    final spoken = ttsRespell(text, headword: headword, headwordPos: headwordPos);

    bool played = false;
    try {
      played = await _speakViaElevenLabs(spoken, langCode, gen)
          .timeout(_elevenLabsTimeout);
    } catch (_) {
      played = false; // timeout, network error, or any other failure
    }
    if (played) return;

    if (gen != _generation) return; // a newer speak() call superseded this one
    _fallbackGeneration = gen;
    await _speakViaFallback(spoken, langCode);
  }

  /// Cache-warming only — fetches and writes [text]'s clip to the on-device
  /// cache (via the same Edge Function + Storage cache as [speak]) without
  /// playing anything. Call this ahead of time (e.g. for a whole deck of
  /// upcoming quiz words) so the real [speak] call later hits an instant
  /// on-device cache hit instead of racing a cold network fetch.
  Future<void> prefetch(
    String text, {
    String langCode = 'en',
    String? headword,
    String? headwordPos,
  }) async {
    if (!appState.voiceOn) return;
    if (!SupabaseConfig.isConfigured) return;
    try {
      final spoken = ttsRespell(text, headword: headword, headwordPos: headwordPos);
      final localPath = await _localCachePath(spoken, langCode);
      if (await File(localPath).exists()) return;

      final res = await Supabase.instance.client.functions.invoke(
        'tts',
        body: {'text': spoken, 'lang': langCode},
      );
      final data = res.data;
      final url = (data is Map) ? data['url'] as String? : null;
      if (url == null) return;

      final bytes = await _download(url);
      if (bytes == null) return;
      await File(localPath).writeAsBytes(bytes, flush: true);
    } catch (_) {
      // Best-effort only — speak() will fetch (and fall back) on demand
      // if this didn't manage to warm the cache in time.
    }
  }

  Future<bool> _speakViaElevenLabs(String text, String langCode, int gen) async {
    if (!SupabaseConfig.isConfigured) return false;
    try {
      final localPath = await _localCachePath(text, langCode);
      final localFile = File(localPath);
      if (await localFile.exists()) {
        if (gen != _generation || gen == _fallbackGeneration) return false;
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

      // This request may have taken long enough that speak() already timed
      // out and fell back to the on-device voice (or a newer speak() call
      // started). Either way the cache write above still happened — we just
      // must not also play over whatever already spoke.
      if (gen != _generation || gen == _fallbackGeneration) return false;
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
