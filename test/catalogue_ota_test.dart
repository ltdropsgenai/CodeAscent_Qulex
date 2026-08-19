import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qulex/data/catalogue_ota.dart';

/// A stand-in bucket on loopback. Serving over real HTTP (rather than mocking
/// HttpClient) is deliberate: the parts most likely to be wrong here are the
/// streaming gzip inflate, the byte counting and the digest — none of which a
/// mock would exercise.
class _FakeBucket {
  late HttpServer server;
  final Map<String, List<int>> files = {};
  final Map<String, int> hits = {};

  /// Set to truncate the payload response mid-stream.
  int? truncateAfter;

  String get base => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final name = req.uri.path.substring(1);
      hits[name] = (hits[name] ?? 0) + 1;
      final body = files[name];
      if (body == null) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      req.response.statusCode = 200;
      final cut = truncateAfter;
      if (cut != null && name != 'manifest.json' && cut < body.length) {
        req.response.add(body.sublist(0, cut));
        await req.response.flush();
        // Close the socket without finishing the body — what a dropped
        // connection actually looks like to the client.
        await req.response.close();
        return;
      }
      req.response.add(body);
      await req.response.close();
    });
  }

  Future<void> stop() => server.close(force: true);
}

/// The smallest thing WordRepository can parse, so a test catalogue is a few
/// hundred bytes instead of 25MB.
String catalogueJson(String id, String word) => json.encode([
      {
        'id': id,
        'lang': 'en',
        'word': word,
        'pos': 'noun',
        'freqRank': 1,
        'difficulty': 'easy',
        'tags': <String>[],
        'gloss': {
          'en': {
            'correct': 'a test word',
            'distractors': ['nope', 'also nope'],
            'example': {'text': 'This is $word.'},
          }
        },
      }
    ]);

void main() {
  late Directory dir;
  late _FakeBucket bucket;
  late CatalogueOta ota;

  /// Publishes [raw] as generation [generation] and returns the manifest map,
  /// so a test can corrupt one field and see what the client does.
  Map<String, dynamic> publish(
    String raw, {
    required int generation,
    int minAppBuild = 0,
    bool disabled = false,
  }) {
    final bytes = utf8.encode(raw);
    final path = 'words-g$generation.json.gz';
    bucket.files[path] = gzip.encode(bytes);
    return {
      'schema': 1,
      'generation': generation,
      'minAppBuild': minAppBuild,
      'path': path,
      'bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
      'disabled': disabled,
    };
  }

  void serveManifest(Map<String, dynamic> m) {
    bucket.files['manifest.json'] = utf8.encode(json.encode(m));
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qulex_ota_test');
    bucket = _FakeBucket();
    await bucket.start();
    // A fresh instance per test would be cleaner, but the class is a singleton
    // on purpose (one download at a time, one pointer). Re-pointing its seams
    // gives the same isolation.
    ota = CatalogueOta.instance
      ..storageDirOverride = dir
      ..baseUrl = bucket.base
      ..appBuild = 100
      ..warnings.clear();
  });

  tearDown(() async {
    await bucket.stop();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<List<String>> names() async =>
      (await dir.list().toList()).map((e) => p.basename(e.path)).toList()
        ..sort();

  test('installs a newer catalogue and points at it', () async {
    serveManifest(publish(catalogueJson('w1', 'aurora'), generation: 2));

    expect(await ota.check(force: true), CatalogueCheckOutcome.installed);

    final path = await ota.activeCataloguePath();
    expect(path, isNotNull);
    expect(File(path!).readAsStringSync(), contains('aurora'));
    // No .part left behind, and exactly one payload kept.
    expect(await names(), ['active.json', 'catalogue-2.json', 'state.json']);
  });

  test('ignores a catalogue no newer than the bundled one', () async {
    // kBundledCatalogueGeneration is 1, so generation 1 is a no-op: the asset
    // in the binary is already this content.
    serveManifest(publish(catalogueJson('w1', 'aurora'), generation: 1));

    expect(await ota.check(force: true), CatalogueCheckOutcome.upToDate);
    expect(await ota.activeCataloguePath(), isNull);
    expect(bucket.hits.containsKey('words-g1.json.gz'), isFalse,
        reason: 'must not spend 6MB of a learner\'s data to learn nothing');
  });

  test('refuses a catalogue that declares it needs a newer build', () async {
    ota.appBuild = 30;
    serveManifest(
        publish(catalogueJson('w1', 'aurora'), generation: 2, minAppBuild: 31));

    expect(await ota.check(force: true), CatalogueCheckOutcome.upToDate);
    expect(await ota.activeCataloguePath(), isNull);

    // ...and takes it once the build catches up.
    ota.appBuild = 31;
    expect(await ota.check(force: true), CatalogueCheckOutcome.installed);
    expect(await ota.activeCataloguePath(), isNotNull);
  });

  test('rejects a payload whose hash does not match the manifest', () async {
    final m = publish(catalogueJson('w1', 'aurora'), generation: 2);
    // One flipped hex digit — the shape stays valid, the content does not.
    m['sha256'] = 'f${(m['sha256'] as String).substring(1)}';
    serveManifest(m);

    expect(await ota.check(force: true), CatalogueCheckOutcome.failed);
    expect(await ota.activeCataloguePath(), isNull);
    expect(await names(), ['state.json'],
        reason: 'a failed download must leave nothing behind');
  });

  test('rejects a payload that is shorter than the manifest says', () async {
    serveManifest(publish(catalogueJson('w1', 'aurora'), generation: 2));
    bucket.truncateAfter = 40; // cut the gzip stream mid-member

    expect(await ota.check(force: true), CatalogueCheckOutcome.failed);
    expect(await ota.activeCataloguePath(), isNull);
    expect(await names(), ['state.json']);
  });

  test('cuts off a payload that inflates past its declared size', () async {
    // A gzip bomb in miniature: the manifest claims a small catalogue, the
    // blob expands to far more. Nothing here is hashed or kept.
    final honest = catalogueJson('w1', 'aurora');
    final m = publish(honest, generation: 2);
    bucket.files[m['path'] as String] =
        gzip.encode(utf8.encode(List.filled(400000, 'x').join()));
    serveManifest(m);

    expect(await ota.check(force: true), CatalogueCheckOutcome.failed);
    expect(await names(), ['state.json']);
  });

  test('ignores a manifest whose path tries to leave the bucket', () async {
    final m = publish(catalogueJson('w1', 'aurora'), generation: 2);
    m['path'] = '../../object/public/tts-cache/en/a2923ae.mp3';
    serveManifest(m);

    expect(await ota.check(force: true), CatalogueCheckOutcome.upToDate);
    expect(await ota.activeCataloguePath(), isNull);
  });

  test('ignores a manifest in a schema it does not understand', () async {
    final m = publish(catalogueJson('w1', 'aurora'), generation: 2);
    m['schema'] = 99;
    serveManifest(m);

    expect(await ota.check(force: true), CatalogueCheckOutcome.upToDate);
    expect(await ota.activeCataloguePath(), isNull);
  });

  test('ignores a manifest that is not JSON at all', () async {
    bucket.files['manifest.json'] = utf8.encode('<html>504 gateway</html>');
    expect(await ota.check(force: true), CatalogueCheckOutcome.upToDate);
    expect(await ota.activeCataloguePath(), isNull);
  });

  test('withdraws an installed catalogue when the manifest is disabled',
      () async {
    serveManifest(publish(catalogueJson('w1', 'aurora'), generation: 2));
    expect(await ota.check(force: true), CatalogueCheckOutcome.installed);
    expect(await ota.activeCataloguePath(), isNotNull);

    // Same generation, now withdrawn. This is the rollback path: it does not
    // need a new catalogue, a new build, or a version bump.
    final off = publish(catalogueJson('w1', 'aurora'), generation: 2);
    off['disabled'] = true;
    serveManifest(off);

    expect(await ota.check(force: true), CatalogueCheckOutcome.revoked);
    expect(await ota.activeCataloguePath(), isNull);
    expect(await names(), ['state.json'],
        reason: 'the withdrawn 25MB must actually be reclaimed');
  });

  test('drops the downloaded copy once a build ships the same generation',
      () async {
    serveManifest(publish(catalogueJson('w1', 'aurora'), generation: 2));
    expect(await ota.check(force: true), CatalogueCheckOutcome.installed);

    // Simulate the store update: the pointer now names a generation that is
    // no newer than the asset compiled in. Rewritten by hand because the
    // constant it is compared against is compile-time.
    await File(p.join(dir.path, 'active.json')).writeAsString(json.encode({
      'generation': kBundledCatalogueGeneration,
      'bytes': 10,
      'sha256': '0' * 64,
      'installedAtMs': 0,
    }));

    expect(await ota.activeCataloguePath(), isNull);
    expect(await names(), ['state.json']);
  });

  test('drops a pointer whose payload went missing', () async {
    serveManifest(publish(catalogueJson('w1', 'aurora'), generation: 2));
    expect(await ota.check(force: true), CatalogueCheckOutcome.installed);
    await File(p.join(dir.path, 'catalogue-2.json')).delete();

    expect(await ota.activeCataloguePath(), isNull);
    expect(await File(p.join(dir.path, 'active.json')).exists(), isFalse);
  });

  test('drops a pointer whose payload is the wrong length', () async {
    serveManifest(publish(catalogueJson('w1', 'aurora'), generation: 2));
    expect(await ota.check(force: true), CatalogueCheckOutcome.installed);
    // Truncation after install — bit rot, a full disk, an interrupted copy.
    await File(p.join(dir.path, 'catalogue-2.json')).writeAsString('[');

    expect(await ota.activeCataloguePath(), isNull);
    expect(await names(), ['state.json']);
  });

  test('does not re-download a generation it already has', () async {
    serveManifest(publish(catalogueJson('w1', 'aurora'), generation: 2));
    expect(await ota.check(force: true), CatalogueCheckOutcome.installed);
    expect(bucket.hits['words-g2.json.gz'], 1);

    expect(await ota.check(force: true), CatalogueCheckOutcome.upToDate);
    expect(bucket.hits['words-g2.json.gz'], 1);
  });

  test('replaces an older download and deletes it', () async {
    serveManifest(publish(catalogueJson('w1', 'aurora'), generation: 2));
    expect(await ota.check(force: true), CatalogueCheckOutcome.installed);

    serveManifest(publish(catalogueJson('w2', 'petrichor'), generation: 3));
    expect(await ota.check(force: true), CatalogueCheckOutcome.installed);

    final path = await ota.activeCataloguePath();
    expect(File(path!).readAsStringSync(), contains('petrichor'));
    expect(await names(), ['active.json', 'catalogue-3.json', 'state.json']);
  });

  test('rate-limits itself between checks, and counts failures', () async {
    serveManifest(publish(catalogueJson('w1', 'aurora'), generation: 2));
    expect(await ota.check(force: true), CatalogueCheckOutcome.installed);
    // The whole point: a background timer that fires often must not turn into
    // a request per firing.
    expect(await ota.check(), CatalogueCheckOutcome.skipped);
    expect(bucket.hits['manifest.json'], 1);

    bucket.files.remove('manifest.json');
    expect(await ota.check(force: true), CatalogueCheckOutcome.failed);
    final state =
        json.decode(await File(p.join(dir.path, 'state.json')).readAsString());
    expect(state['failCount'], 1);
  });

  test('survives the server being unreachable', () async {
    await bucket.stop();
    expect(await ota.check(force: true), CatalogueCheckOutcome.failed);
    expect(await ota.activeCataloguePath(), isNull);
  });
}
