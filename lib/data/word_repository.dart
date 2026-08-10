import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import '../models/word.dart';

/// Loads the bundled seed dataset. Swap this for a Supabase/API call later —
/// the rest of the app only depends on `loadAll()` returning `List<Word>`.
class WordRepository {
  Future<List<Word>> loadAll() async {
    final raw = await rootBundle.loadString('assets/words.json');
    final list = json.decode(raw) as List<dynamic>;
    return list
        .map((e) => Word.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }
}
