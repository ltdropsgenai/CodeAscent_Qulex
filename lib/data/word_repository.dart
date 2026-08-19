import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;

import '../models/word.dart';

/// Decodes the catalogue. Top-level (not a method) so it can be handed to a
/// background isolate.
List<Word> _decodeCatalogue(String raw) {
  final list = json.decode(raw) as List<dynamic>;
  return list
      .map((e) => Word.fromJson(e as Map<String, dynamic>))
      .toList(growable: false);
}

/// Loads the bundled seed dataset. Swap this for a Supabase/API call later —
/// the rest of the app only depends on `loadAll()` returning `List<Word>`.
class WordRepository {
  /// Reads and decodes assets/words.json.
  ///
  /// The decode runs on a BACKGROUND isolate. assets/words.json is ~24MB and
  /// json.decode is synchronous, so doing it inline blocks the main isolate
  /// for roughly a second on desktop and longer on a phone — measured at
  /// 1,020ms here. During that block no frame is produced: the launch
  /// animation freezes, the loading spinner stops turning, and any Timer or
  /// AnimationController carries on counting wall-clock time against a screen
  /// nobody can see updating.
  ///
  /// compute() costs the same wall-clock (1,099ms measured — the copy back is
  /// nearly free) but keeps the UI thread free the whole time, which is the
  /// only thing that actually matters here.
  ///
  /// rootBundle is main-isolate only, so the read stays here (~1ms) and only
  /// the decode is shipped out.
  Future<List<Word>> loadAll() async {
    final raw = await rootBundle.loadString('assets/words.json');
    return compute(_decodeCatalogue, raw);
  }
}
