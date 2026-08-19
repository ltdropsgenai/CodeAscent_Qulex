import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;

import '../models/word.dart';
import 'catalogue_ota.dart';

/// Decodes the catalogue. Top-level (not a method) so it can be handed to a
/// background isolate.
List<Word> _decodeCatalogue(String raw) {
  final list = json.decode(raw) as List<dynamic>;
  return list
      .map((e) => Word.fromJson(e as Map<String, dynamic>))
      .toList(growable: false);
}

/// Reads AND decodes a catalogue file, entirely inside the background isolate.
///
/// Only the path crosses the isolate boundary. Reading on the main isolate and
/// shipping the string across would copy 25MB for no reason — and the copy is
/// on the main isolate, which is exactly the thread this is trying to protect.
List<Word> _decodeCatalogueFile(String path) =>
    _decodeCatalogue(File(path).readAsStringSync());

/// Loads the word catalogue: the copy pushed over the air if there is a newer
/// verified one, otherwise the copy compiled into the binary.
class WordRepository {
  /// Reads and decodes the catalogue.
  ///
  /// The decode runs on a BACKGROUND isolate. The catalogue is ~25MB and
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
  /// The over-the-air path is checked first but never waits on the network:
  /// [CatalogueOta.activeCataloguePath] only reads a small pointer file
  /// written by an earlier background download. If that catalogue does not
  /// parse — the one failure mode a SHA-256 cannot rule out, because a file
  /// can be byte-perfect and still describe something this build cannot
  /// model — it is discarded and the bundled asset is used, so a bad content
  /// push degrades to the shipped word list instead of an empty app.
  Future<List<Word>> loadAll() async {
    final otaPath = await CatalogueOta.instance.activeCataloguePath();
    if (otaPath != null) {
      try {
        return await compute(_decodeCatalogueFile, otaPath);
      } catch (_) {
        await CatalogueOta.instance
            .discardInstalled('it could not be read by this version');
      }
    }
    // rootBundle is main-isolate only, so the read stays here (~1ms) and only
    // the decode is shipped out.
    final raw = await rootBundle.loadString('assets/words.json');
    return compute(_decodeCatalogue, raw);
  }
}
