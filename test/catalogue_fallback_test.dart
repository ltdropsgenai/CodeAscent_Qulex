import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qulex/data/catalogue_ota.dart';

import 'package:qulex/data/word_repository.dart';

import 'catalogue_ota_test.dart' show catalogueJson;
/// One generation newer than whatever this build bundles — see the same
/// constant in catalogue_ota_test.dart for why this is not a literal.
const int kNewer = kBundledCatalogueGeneration + 1;

/// Installs [raw] as generation [generation] by hand — bypassing the download
/// entirely, because what is under test here is the READ side: which file
/// WordRepository picks, and what it does when that file turns out to be
/// unusable.
Future<void> installByHand(Directory dir, String raw, int generation) async {
  final f = File(p.join(dir.path, 'catalogue-$generation.json'));
  await f.writeAsString(raw, flush: true);
  await File(p.join(dir.path, 'active.json')).writeAsString(json.encode({
    'generation': generation,
    'bytes': await f.length(),
    'sha256': '0' * 64,
    'installedAtMs': 0,
  }));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qulex_fallback_test');
    CatalogueOta.instance
      ..storageDirOverride = dir
      ..warnings.clear();
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('reads the installed catalogue instead of the bundled asset', () async {
    await installByHand(dir, catalogueJson('ota1', 'petrichor'), kNewer);

    final words = await WordRepository().loadAll();

    expect(words, hasLength(1));
    expect(words.single.word, 'petrichor');
  });

  test('falls back to the bundled asset when the installed copy is unusable',
      () async {
    // Byte-perfect against its own recorded length, so nothing on the read
    // path can tell it is bad until something tries to parse it. This is the
    // failure a SHA-256 cannot catch: a file can be exactly the bytes that
    // were published and still describe something this build cannot model.
    await installByHand(dir, '[{"id":"x","this":"is not a Word"}]', kNewer);

    final words = await WordRepository().loadAll();

    // The real catalogue, not the one-entry decoy — and ALL of it. This used
    // to assert "more than 1000", which a fallback that silently truncated the
    // bundled asset would have passed.
    expect(words.length, kBundledCatalogueEntries);
    // ...and the bad copy is gone, so the next launch does not retry it.
    expect(await CatalogueOta.instance.activeCataloguePath(), isNull);
    expect(await File(p.join(dir.path, 'active.json')).exists(), isFalse);
    expect(CatalogueOta.instance.warnings, isNotEmpty);
  });

  test('uses the bundled asset when nothing has been installed', () async {
    // The offline first run, and the reason the whole 38MB file is in the
    // binary: no network, no OTA download, nothing installed — and every word
    // is still there.
    final words = await WordRepository().loadAll();
    expect(words.length, kBundledCatalogueEntries);
  });

  test('an installed catalogue never leaves the learner with fewer words',
      () async {
    // The OTA path can only ever REPLACE the bundled list, so a published
    // catalogue smaller than the one in the binary is a downgrade the learner
    // did not ask for. Nothing stops it today; this records what happens so a
    // future change to _shouldTake has to answer for it.
    await installByHand(dir, catalogueJson('ota1', 'petrichor'), kNewer);
    final words = await WordRepository().loadAll();
    expect(words, hasLength(1),
        reason: 'if this ever fails, the read side started merging rather than '
            'replacing, and the fallback tests above no longer mean what they '
            'say');
  });
}
