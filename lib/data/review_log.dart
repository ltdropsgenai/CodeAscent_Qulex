import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../game/srs.dart';

/// An append-only record of every answer, kept so FSRS can eventually be
/// fitted to the learner instead of running on someone else's averages.
///
/// WHY THIS EXISTS. Qulex ships the published FSRS-5 default parameters, which
/// were fitted across roughly 20k Anki collections. They are a large
/// improvement on Leitner boxes and they are still, unavoidably, a stranger's
/// memory. Anki retrains its parameters against your own review history after a
/// few hundred reviews and gets materially better at predicting YOUR
/// forgetting. Qulex cannot do that today for one boring reason: it has never
/// written the history down. Nothing can be fitted to data that was not kept.
///
/// So this lands first, alone, and does nothing visible. It is the unglamorous
/// half of the feature, and it has to ship a build ahead of the optimiser
/// because on the day the optimiser arrives it will need months of history that
/// only exists if collection started today.
///
/// WHAT AN OPTIMISER ACTUALLY NEEDS. Not the scheduler's internal state — that
/// is derivable. FSRS fitting replays each card's reviews in order and compares
/// the model's predicted recall against what happened, so the irreducible
/// record is (which word, when, how it went). Everything else — stability,
/// difficulty, elapsed time, retrievability — is reconstructed by the replay
/// using whatever parameters are being tested. Storing the derived values would
/// bake in the CURRENT parameters and quietly make the log useless for fitting
/// new ones.
///
/// The one extra field is the learning phase, because FSRS treats a review
/// inside the learning steps differently from a graduated one, and that is not
/// recoverable from timestamps alone.
///
/// SHAPE ON DISK. One line per review, comma separated, no quoting — word ids
/// are `[A-Za-z0-9_]` by construction and the other three fields are numbers or
/// a single letter:
///
///     w_always,1770000000000,3,r
///     w_abate,1770000041233,1,l
///
/// About 30 bytes a review. Append-only, so a review costs one short write
/// rather than re-encoding the whole history the way a shared_preferences blob
/// would. It is deliberately NOT in shared_preferences: that is a
/// read-modify-write of a single value, which at 50,000 reviews would mean
/// rewriting 1.5MB on every answer.
class ReviewLog {
  ReviewLog._();
  static final ReviewLog instance = ReviewLog._();

  /// Test seam — avoids standing up path_provider.
  ///
  /// Setting it invalidates the memoised handle and the loaded count, because
  /// otherwise pointing the log at a new directory would keep appending to the
  /// old one. That is a real bug the first version of review_log_test.dart
  /// found immediately: every test after the first read an empty file.
  Directory? get storageDirOverride => _storageDirOverride;
  set storageDirOverride(Directory? d) {
    _storageDirOverride = d;
    _file = null;
    _loaded = false;
    _knownCount = 0;
    _pending.clear();
  }

  Directory? _storageDirOverride;

  static const String _fileName = 'reviews.csv';

  /// Hard ceiling on retained reviews.
  ///
  /// 50,000 is about 1.5MB and several years of daily study at Qulex's pace.
  /// When it is exceeded the OLDEST fifth is dropped, not the newest: recent
  /// history is what predicts near-term forgetting, and an optimiser handles a
  /// card whose first few reviews are missing by starting its replay at the
  /// first review it can see. Losing the tail is a small loss of fitting
  /// accuracy; losing the head would mean losing what the learner is doing now.
  static const int maxEntries = 50000;

  /// How many reviews an optimiser needs before fitting means anything.
  ///
  /// Below roughly this many, a fit is noise dressed as personalisation — it
  /// will happily produce parameters that are worse than the published
  /// defaults. Anki uses a threshold in the same region. Exposed so the UI can
  /// say "personalisation unlocks at 400 reviews" instead of offering a button
  /// that quietly does harm.
  static const int fitThreshold = 400;

  final List<String> _pending = <String>[];
  File? _file;
  int _knownCount = 0;
  bool _loaded = false;

  /// Reviews banked so far, including ones still in the buffer.
  int get count => _knownCount + _pending.length;

  bool get canFit => count >= fitThreshold;

  static String _phase(SrsState s) => switch (s) {
        SrsState.fresh => 'n', // new
        SrsState.learning => 'l',
        SrsState.review => 'r',
        SrsState.relearning => 'g', // relearning
      };

  Future<Directory> _dir() async {
    final o = _storageDirOverride;
    if (o != null) {
      if (!await o.exists()) await o.create(recursive: true);
      return o;
    }
    // Support dir, not documents: this is machine state, not something the
    // learner should see in Files or have swept up by an iCloud backup policy
    // aimed at user documents.
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'qulex_review_log'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File> _handle() async {
    if (_file != null) return _file!;
    final d = await _dir();
    return _file = File(p.join(d.path, _fileName));
  }

  /// Counts what is already on disk. Cheap, and only done once per launch.
  Future<void> load() async {
    if (_loaded || kIsWeb) return;
    _loaded = true;
    try {
      final f = await _handle();
      if (!await f.exists()) {
        _knownCount = 0;
        return;
      }
      // Counting newlines rather than parsing: nothing here needs the values
      // until an optimiser asks for them.
      final bytes = await f.readAsBytes();
      var n = 0;
      for (final b in bytes) {
        if (b == 0x0A) n++;
      }
      _knownCount = n;
    } catch (_) {
      // A missing or unreadable log is not a reason to stop the app working.
      // It costs future personalisation accuracy and nothing else.
      _knownCount = 0;
    }
  }

  /// Records one answer. Buffered — see [flush].
  ///
  /// [phaseBefore] is the state the word was in when the question was asked,
  /// not after; the whole point is to capture the input to the scheduler
  /// rather than its output.
  void record({
    required String wordId,
    required int atMillis,
    required Grade grade,
    required SrsState phaseBefore,
  }) {
    if (kIsWeb) return;
    _pending.add('$wordId,$atMillis,${grade.value},${_phase(phaseBefore)}');
  }

  /// Appends whatever is buffered. Safe to call when there is nothing to do.
  ///
  /// Called from ProgressStore.flush(), so the log is written on exactly the
  /// same beats the progress it describes is — one fsync-ish moment per round
  /// rather than one per answer.
  Future<void> flush() async {
    if (kIsWeb || _pending.isEmpty) return;
    final batch = List<String>.from(_pending);
    _pending.clear();
    try {
      final f = await _handle();
      await f.writeAsString('${batch.join('\n')}\n',
          mode: FileMode.append, flush: false);
      _knownCount += batch.length;
      if (_knownCount > maxEntries) await _compact();
    } catch (_) {
      // Dropped rather than retried forever. A lost batch is a slightly worse
      // future fit; a retry loop on a full disk is a hang.
    }
  }

  /// Drops the oldest fifth once the ceiling is passed.
  ///
  /// Rewrites the file, which is expensive — and happens once every 10,000
  /// reviews rather than on a boundary that could be hit repeatedly.
  Future<void> _compact() async {
    try {
      final f = await _handle();
      final lines = const LineSplitter().convert(await f.readAsString())
        ..removeWhere((l) => l.isEmpty);
      if (lines.length <= maxEntries) {
        _knownCount = lines.length;
        return;
      }
      final keep = lines.sublist(lines.length - (maxEntries * 4 ~/ 5));
      await f.writeAsString('${keep.join('\n')}\n');
      _knownCount = keep.length;
    } catch (_) {
      /* leave it oversized rather than risk losing all of it */
    }
  }

  /// The whole history, oldest first, for a future optimiser.
  ///
  /// Returns entries that failed to parse as nothing rather than throwing —
  /// one corrupt line (a half-written append after a kill) must not cost the
  /// other 49,999.
  Future<List<ReviewRecord>> readAll() async {
    if (kIsWeb) return const [];
    await flush();
    try {
      final f = await _handle();
      if (!await f.exists()) return const [];
      final out = <ReviewRecord>[];
      for (final line in const LineSplitter().convert(await f.readAsString())) {
        if (line.isEmpty) continue;
        final parts = line.split(',');
        if (parts.length != 4) continue;
        final at = int.tryParse(parts[1]);
        final g = int.tryParse(parts[2]);
        if (at == null || g == null || g < 1 || g > 4) continue;
        out.add(ReviewRecord(
          wordId: parts[0],
          atMillis: at,
          grade: Grade.values[g - 1],
          phase: parts[3],
        ));
      }
      // Appends are chronological, but a compaction or a clock change could
      // disturb that, and a replay that runs out of order is silently wrong.
      out.sort((a, b) => a.atMillis.compareTo(b.atMillis));
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Wipes the history. Offered in Settings next to the other destructive
  /// actions, because a log of what you studied and when is personal data and
  /// the learner should be able to say no to it.
  Future<void> clear() async {
    _pending.clear();
    _knownCount = 0;
    if (kIsWeb) return;
    try {
      final f = await _handle();
      if (await f.exists()) await f.writeAsString('');
    } catch (_) {/* nothing useful to do */}
  }
}

class ReviewRecord {
  final String wordId;
  final int atMillis;
  final Grade grade;

  /// 'n' new, 'l' learning, 'r' review, 'g' relearning — the phase the word was
  /// in when it was asked.
  final String phase;

  const ReviewRecord({
    required this.wordId,
    required this.atMillis,
    required this.grade,
    required this.phase,
  });
}
