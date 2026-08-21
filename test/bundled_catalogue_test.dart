import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qulex/data/catalogue_ota.dart';
import 'package:qulex/models/word.dart';

/// What a build actually carries in its binary.
///
/// Qulex bundles the whole 38MB catalogue rather than downloading it, so a
/// first run works on a plane. That promise is only as good as the file in
/// assets/, and nothing about that file announces itself: it is a bare JSON
/// array with no version, no count and no checksum. A truncated write, a
/// half-finished regeneration, or a commit that carries new words without
/// bumping kBundledCatalogueGeneration all produce a build that looks fine,
/// analyses clean, passes every other test, and ships the wrong word list.
///
/// This is the file that notices. It is deliberately about identity rather than
/// content — dataset_test.dart already checks that entries parse and mean
/// something; what nothing checked was whether there are all of them.
void main() {
  final asset = File('assets/words.json');

  test('the bundled asset is present where the build expects it', () {
    expect(asset.existsSync(), isTrue,
        reason: 'assets/words.json missing — an offline first run has no words '
            'at all. Run tests from the package root.');

    // Declared in pubspec, or Flutter never puts it in the binary and the app
    // fails at runtime rather than here. The Shorebird line two entries below
    // it was deleted once and cost a build; this section is worth asserting on.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- assets/words.json'),
        reason: 'the asset exists on disk but is not bundled into the app');
  });

  test('it is byte-for-byte the catalogue this build claims to bundle', () {
    final bytes = asset.readAsBytesSync();
    final sha = sha256.convert(bytes).toString();
    expect(sha, kBundledCatalogueSha256,
        reason: 'assets/words.json is not the file kBundledCatalogueSha256 '
            'names.\n'
            'If you regenerated the catalogue on purpose, bump all three '
            'constants in lib/data/catalogue_ota.dart in the SAME commit:\n'
            '  kBundledCatalogueGeneration = ${kBundledCatalogueGeneration + 1}\n'
            '  kBundledCatalogueEntries    = <the count this test prints next>\n'
            "  kBundledCatalogueSha256     = '$sha'\n"
            'Shipping a build whose generation number disagrees with its own '
            'words is the mistake this test exists for.');
  });

  test('it holds every entry, not merely a plausible number of them', () {
    final list = json.decode(asset.readAsStringSync()) as List<dynamic>;
    expect(list.length, kBundledCatalogueEntries,
        reason: 'the bundled catalogue has ${list.length} entries, not '
            '$kBundledCatalogueEntries. Every other test in this suite asserts '
            '"more than 1000", which a half-written file passes.');

    // And it is really the app's parser, not just valid JSON. A file can be
    // the right length and still be missing a field this build requires; the
    // client's only defence then is to fall back, which works and is silent.
    final words = list
        .map((e) => Word.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
    expect(words.length, kBundledCatalogueEntries);
    expect(words.map((w) => w.id).toSet().length, kBundledCatalogueEntries,
        reason: 'duplicate ids — progress is keyed by id, so two words would '
            'share one learner\'s review schedule');
  });

  test('the generation constant is a number a client can act on', () {
    // _shouldTake compares with `>`, so zero and negatives strand every
    // install on whatever it last downloaded.
    expect(kBundledCatalogueGeneration, greaterThan(0));
    expect(kBundledCatalogueSha256, hasLength(64));
    expect(kBundledCatalogueEntries, greaterThan(0));
  });
}
