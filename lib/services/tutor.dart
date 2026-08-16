import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_config.dart';

/// A short AI explanation + fresh example for one word, in one language.
class WordExplanation {
  final String explanation;
  final String example;
  const WordExplanation({required this.explanation, required this.example});
}

/// Bounded "explain this word" AI-tutor helper — a single-shot call per
/// (word, language) tap, never an open-ended chat. Deliberately narrow:
/// no conversation state, no follow-up questions, no unbounded user input.
/// That keeps the interaction cheap and its cost capped by the size of the
/// word library (server-side cached once per word+language, shared across
/// every user via the `explain` Supabase Edge Function), rather than
/// scaling with how much any one user types — unlike an open chat tutor.
class Tutor {
  Tutor._();
  static final Tutor instance = Tutor._();

  // In-memory only: a second tap on the same word this session shouldn't
  // re-hit the network, but this isn't meant to survive app restarts — the
  // server-side cache (one row per word+lang, forever) already does that.
  final Map<String, WordExplanation> _cache = {};

  String _key(String wordId, String lang) => '$wordId|$lang';

  /// Returns null on any failure (not configured, network, parse error) —
  /// callers should treat that as "unavailable right now" for this
  /// light bonus feature, not surface a scary error.
  Future<WordExplanation?> explain({
    required String wordId,
    required String word,
    required String definition,
    required String lang,
  }) async {
    final key = _key(wordId, lang);
    final cached = _cache[key];
    if (cached != null) return cached;
    if (!SupabaseConfig.isConfigured) return null;
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'explain',
        body: {'wordId': wordId, 'word': word, 'definition': definition, 'lang': lang},
      );
      final data = res.data;
      if (data is! Map) return null;
      final explanation = data['explanation'] as String?;
      final example = data['example'] as String?;
      if (explanation == null || example == null) return null;
      final result = WordExplanation(explanation: explanation, example: example);
      _cache[key] = result;
      return result;
    } catch (_) {
      return null;
    }
  }
}
