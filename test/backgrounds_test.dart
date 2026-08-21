import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qulex/widgets/app_background.dart';

/// The backdrop is the one part of the app where a file can go missing without
/// anything failing.
///
/// pubspec bundles the whole `assets/backgrounds/` directory, so an image stays
/// in the binary whether or not [kBackgroundScenes] mentions it, and
/// AppBackground simply draws the ones it knows about. That is exactly what
/// happened between 19 and 21 Aug 2026: eight personal photographs were added
/// in 41ce6cc, silently dropped from the list in 2845dab when files were
/// restored from a stale snapshot, and shipped unused in every build after —
/// no crash, no missing asset, no failing test, just half the backdrop gone.
///
/// These two assertions close it in both directions.
void main() {
  final dir = Directory('assets/backgrounds');

  List<String> filesOnDisk() {
    expect(dir.existsSync(), isTrue,
        reason: 'run tests from the package root');
    return dir
        .listSync()
        .whereType<File>()
        .map((f) => 'assets/backgrounds/${f.uri.pathSegments.last}')
        .where((p) => p.endsWith('.png') || p.endsWith('.jpg'))
        .toList()
      ..sort();
  }

  test('every bundled image is actually drawn', () {
    final listed = kBackgroundScenes.toSet();
    final missing = filesOnDisk().where((f) => !listed.contains(f)).toList();
    expect(missing, isEmpty,
        reason: 'these images ship inside the app and are never shown: '
            '${missing.join(", ")}. Either add them to kBackgroundScenes or '
            'delete them — a file that is paid for in binary size and never '
            'drawn is the failure this test exists for.');
  });

  test('every scene the app draws actually exists', () {
    final onDisk = filesOnDisk().toSet();
    final dangling =
        kBackgroundScenes.where((s) => !onDisk.contains(s)).toList();
    expect(dangling, isEmpty,
        reason: 'listed but not on disk: ${dangling.join(", ")}. '
            'AppBackground falls back rather than crashing, so this would show '
            'as an occasional blank scene rather than an error.');
  });

  test('the personal photographs are among them', () {
    // Named explicitly rather than counted. A count passes if eight files are
    // swapped for eight others; the point of these eight is which ones they are.
    for (var i = 9; i <= 16; i++) {
      final path = 'assets/backgrounds/bg_${i.toString().padLeft(2, '0')}.jpg';
      expect(kBackgroundScenes, contains(path));
      expect(File(path).existsSync(), isTrue);
    }
  });
}
