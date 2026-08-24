import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart' show AccumulatorSink;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Generation number of the catalogue compiled into THIS binary.
///
/// Bump this in the same commit that changes assets/words.json, and publish
/// the over-the-air copy at the same number (tools/publish_catalogue.py checks
/// that they agree, and refuses otherwise).
///
/// It is what makes a store update reclaim the 25MB downloaded copy instead of
/// keeping it forever. The rule is one line of [CatalogueOta._shouldTake]:
/// an over-the-air catalogue is only interesting while its generation is
/// HIGHER than the bundled one. Ship a build carrying generation 4 and every
/// client that downloaded generation 4 drops its copy on the next launch,
/// because the asset it already has is just as new.
///
/// Never reuse or lower a number. Clients compare with `>`, so going backwards
/// silently strands them on whatever they last downloaded.
const int kBundledCatalogueGeneration = 3;

/// The identity of the asset THIS build bundles: how many entries it holds and
/// what it hashes to.
///
/// These exist because the generation number above is a promise the file itself
/// cannot keep. `assets/words.json` is a bare JSON array — it carries no
/// version, no count, no checksum — so a regenerated catalogue committed
/// without bumping the constant produces a build that says "I am generation 2"
/// while carrying generation 3's words. That has happened twice: once because a
/// PowerShell `#` turned the bump into a comment, and once because the commit
/// contained only words.json. Both times the mistake was invisible until a
/// publish failed.
///
/// bundled_catalogue_test.dart hashes the real asset against these, so the
/// three constants can only move together, and tools/publish_catalogue.py
/// checks the same three before it will publish. The SHA is the same number the
/// published manifest records, which is what makes "the binary and the bucket
/// hold the same catalogue" a checkable claim rather than a habit.
///
/// To change the catalogue: regenerate the asset, then bump all three in the
/// same commit. The test tells you the values it wanted.
const int kBundledCatalogueEntries = 16808;
const String kBundledCatalogueSha256 =
    '7350b3aaf31bf4058c1d0de11d17e1639dee5438420b84d85f34581bcc6e4052';

/// Where the published catalogue lives. A public Storage bucket, read straight
/// off the CDN — no Edge Function invocation, no auth, no per-read cost.
///
/// Writes are a different matter and never happen from the app: publishing
/// goes through the admin-gated `catalogue-admin` function, which is the only
/// thing holding a service-role key.
const String kCatalogueBucketUrl = String.fromEnvironment(
  'QULEX_CATALOGUE_URL',
  defaultValue:
      'https://fzhguqoodojugeuyosnj.supabase.co/storage/v1/object/public/catalogue',
);

/// A catalogue published over the air, described by manifest.json.
class CatalogueManifest {
  /// Manifest format, so an old client can recognise a shape it cannot read
  /// and leave it alone rather than misinterpreting it.
  final int schema;

  /// Monotonic catalogue generation. Compared against
  /// [kBundledCatalogueGeneration].
  final int generation;

  /// Refuse to serve this catalogue to a binary older than this. The escape
  /// hatch for content that needs code the old build does not have — a new
  /// field, a new part of speech, a new language. Without it, the first
  /// catalogue that outruns its client is a crash loop with no way back.
  final int minAppBuild;

  /// Path of the gzipped payload, relative to [kCatalogueBucketUrl].
  final String path;

  /// Size and SHA-256 of the DECOMPRESSED json — the bytes we actually keep,
  /// not the bytes on the wire. Verifying the transport encoding would leave
  /// a truncated or mis-inflated file undetected.
  final int bytes;
  final String sha256;

  /// Set by the publisher to pull a bad catalogue without waiting for a new
  /// one to be built. Clients seeing it drop their copy and fall back to the
  /// asset in the binary.
  final bool disabled;

  const CatalogueManifest({
    required this.schema,
    required this.generation,
    required this.minAppBuild,
    required this.path,
    required this.bytes,
    required this.sha256,
    required this.disabled,
  });

  static const int supportedSchema = 1;

  /// Returns null rather than throwing for anything malformed: a broken
  /// manifest must degrade to "no update available", never to an exception on
  /// a background timer.
  static CatalogueManifest? tryParse(String raw) {
    try {
      final j = json.decode(raw);
      if (j is! Map<String, dynamic>) return null;
      final schema = j['schema'];
      final generation = j['generation'];
      final path = j['path'];
      final bytes = j['bytes'];
      final sha = j['sha256'];
      if (schema is! int || generation is! int || bytes is! int) return null;
      if (path is! String || sha is! String) return null;
      // A path is joined onto a URL, so it must not be able to climb out of
      // the bucket or point somewhere else entirely.
      if (path.isEmpty ||
          path.length > 200 ||
          path.contains('..') ||
          path.contains('//') ||
          path.startsWith('/') ||
          !RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(path)) {
        return null;
      }
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) return null;
      if (bytes <= 0 || bytes > maxCatalogueBytes) return null;
      return CatalogueManifest(
        schema: schema,
        generation: generation,
        minAppBuild: j['minAppBuild'] is int ? j['minAppBuild'] as int : 0,
        path: path,
        bytes: bytes,
        sha256: sha,
        disabled: j['disabled'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// Hard ceiling on a decompressed catalogue. The payload arrives gzipped, so
  /// without a limit a few hundred KB of zeros inflates until the device runs
  /// out of storage. Today's catalogue is ~25MB.
  static const int maxCatalogueBytes = 96 * 1024 * 1024;
}

/// What a check did, so callers (and tests) can assert on it.
enum CatalogueCheckOutcome {
  /// Disabled, unsupported platform, or checked too recently.
  skipped,

  /// Reached the manifest; nothing newer than what we already have.
  upToDate,

  /// Downloaded, verified and installed. Takes effect on the next cold start.
  installed,

  /// Manifest says stop using the downloaded copy; the local one was dropped.
  revoked,

  /// Network, integrity or disk failure. Nothing changed.
  failed,
}

/// Ships a new catalogue to installed apps without a store release.
///
/// Three rules shape everything here.
///
/// 1. It is never on the launch path. [activeCataloguePath] only reads a small
///    pointer file; the network call lives in [check], which callers schedule
///    well after first frame. A learner opening the app on a hotel wifi
///    captive portal waits for nothing.
///
/// 2. A catalogue is installed, not applied. The download lands in a file
///    named for its generation and the pointer is rewritten last, in one
///    atomic step. The running session keeps the list it already parsed —
///    swapping 25MB of words out from under a deck mid-round would invalidate
///    the daily word, the active session and every scheduled review.
///
/// 3. Nothing is trusted. The manifest is range-checked, the payload is
///    size-capped while inflating, and the SHA-256 is computed over the
///    decompressed bytes and compared before the pointer moves. A file that
///    fails any of it is deleted, not kept for later.
class CatalogueOta {
  CatalogueOta._();
  static final CatalogueOta instance = CatalogueOta._();

  /// Test seam. Injected client is used verbatim and never closed by us.
  HttpClient Function()? httpClientFactory;

  /// Test seam. Overrides the directory the catalogue is stored in, so a test
  /// never has to stand up path_provider.
  Directory? storageDirOverride;

  /// Base URL of the published catalogue. Overridable so a test can point it
  /// at a loopback server instead of production.
  String baseUrl = kCatalogueBucketUrl;

  /// The build number this binary was compiled at, checked against the
  /// manifest's `minAppBuild`.
  ///
  /// Defaults to 0, and CI passes the real one
  /// (`--dart-define=QULEX_BUILD_NUMBER=$BUILD_NUMBER`). Zero is the safe
  /// default in both directions: a manifest that sets no floor uses
  /// minAppBuild 0, so a build that somehow shipped without the define still
  /// receives ordinary content pushes — but it is excluded from any catalogue
  /// that explicitly declares it needs newer code. The failure mode of a
  /// missing define is "misses a gated push", not "installs content it cannot
  /// parse".
  int appBuild = const int.fromEnvironment('QULEX_BUILD_NUMBER');

  /// How long between manifest checks.
  ///
  /// This is a rollback-latency dial, not a freshness one. A check is a ~200
  /// byte CDN read and downloads nothing unless the generation changed, so the
  /// only thing a longer interval buys is a slightly quieter radio — while the
  /// thing it costs is how long a bad catalogue stays live on a device after
  /// someone has already pulled it. Two hours, plus up to a minute of CDN
  /// cache on the manifest itself, is the worst case for a withdrawal to
  /// reach a device that stays open.
  ///
  /// In practice most learners see one check per launch either way: the timer
  /// is armed once from HomeScreen, so this only bites for someone opening the
  /// app repeatedly.
  static const Duration _minCheckInterval = Duration(hours: 2);
  static const Duration _manifestTimeout = Duration(seconds: 12);
  static const Duration _payloadTimeout = Duration(minutes: 5);

  Directory? _dir;
  bool _checking = false;

  /// Warnings worth surfacing (a dropped catalogue, a failed verification).
  /// Same contract as ProgressStore.loadWarnings — read after a call, never
  /// thrown.
  final List<String> warnings = [];

  Future<Directory> _storageDir() async {
    if (storageDirOverride != null) return storageDirOverride!;
    if (_dir != null) return _dir!;
    // Application-support, matching the TTS cache: the temp dir gets wiped
    // under storage pressure, which would silently undo a content push.
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'qulex_catalogue'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  // Every path in this class is built with p.join and compared by FILENAME,
  // never by full path.
  //
  // This is not tidiness. The first version concatenated '$dir/$name' and had
  // _sweep skip the file it had just installed by testing `entity.path == keep`
  // — which on Windows compares 'C:\\...\\qulex_catalogue/catalogue-2.json'
  // against 'C:\\...\\qulex_catalogue\\catalogue-2.json'. Both open the same
  // file; neither equals the other. The sweep deleted the catalogue one line
  // after verifying and installing it, and the next launch found a pointer to
  // nothing. A filename has no separator in it, so there is nothing left to get
  // wrong.
  static String _payloadName(int generation) => 'catalogue-$generation.json';
  static const String _pointerName = 'active.json';
  static const String _stateName = 'state.json';

  File _pointerFile(Directory d) => File(p.join(d.path, _pointerName));
  File _stateFile(Directory d) => File(p.join(d.path, _stateName));
  File _payloadFile(Directory d, int generation) =>
      File(p.join(d.path, _payloadName(generation)));

  /// Path of the installed catalogue to read INSTEAD of assets/words.json, or
  /// null to use the bundled asset.
  ///
  /// Cheap on purpose — one small read and a stat. Everything expensive
  /// (network, hashing, inflating) happened on a previous run.
  Future<String?> activeCataloguePath() async {
    if (kIsWeb) return null;
    try {
      final dir = await _storageDir();
      final ptr = _pointerFile(dir);
      if (!await ptr.exists()) return null;
      final j = json.decode(await ptr.readAsString());
      if (j is! Map<String, dynamic>) return null;
      final generation = j['generation'];
      if (generation is! int || !_shouldTake(generation)) {
        // A store update has caught up with, or overtaken, what we downloaded.
        // Reclaim the space rather than carrying a redundant 25MB forever.
        await _dropInstalled('superseded by the bundled catalogue');
        return null;
      }
      final file = _payloadFile(dir, generation);
      if (!await file.exists()) {
        await _dropInstalled('installed catalogue file is missing');
        return null;
      }
      // Length is a cheap tripwire for truncation; the SHA-256 was verified
      // at install and re-hashing 25MB on every launch would cost more than
      // the whole thing saves.
      final expected = j['bytes'];
      if (expected is int && await file.length() != expected) {
        await _dropInstalled('installed catalogue is the wrong size');
        return null;
      }
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Called when the installed catalogue turned out not to parse. Drops it so
  /// the next launch starts from the bundled asset rather than failing again.
  Future<void> discardInstalled(String why) => _dropInstalled(why);

  bool _shouldTake(int generation) => generation > kBundledCatalogueGeneration;

  Future<void> _dropInstalled(String why) async {
    warnings.add('Downloaded word list dropped — $why.');
    try {
      final dir = await _storageDir();
      final ptr = _pointerFile(dir);
      if (await ptr.exists()) await ptr.delete();
      await _sweep(dir, keepGeneration: null);
    } catch (_) {/* housekeeping only */}
  }

  /// Deletes every payload except the one currently pointed at.
  Future<void> _sweep(Directory dir, {required int? keepGeneration}) async {
    try {
      final keep =
          keepGeneration == null ? null : _payloadName(keepGeneration);
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        final isPayload = name.startsWith('catalogue-') && name.endsWith('.json');
        final isPart = name.endsWith('.part');
        if (!isPayload && !isPart) continue;
        if (name == keep) continue;
        try {
          await e.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Schedules a check for [after] from now and swallows everything.
  ///
  /// Deliberately does not return a Future. A caller that awaited this would
  /// put the network back on the path this whole class exists to keep it off.
  ///
  /// It DOES return the timer, and the caller is expected to cancel it on
  /// dispose. The first version returned void and armed an unowned timer —
  /// which outlives the screen that armed it, keeps the isolate awake for
  /// twelve seconds after the app is done with it, and shows up in widget
  /// tests as "a Timer is still pending even after the widget tree was
  /// disposed". Nothing in this class needs to outlive its caller.
  Timer? scheduleCheck({Duration after = const Duration(seconds: 12)}) {
    if (kIsWeb) return null;
    return Timer(after, () {
      unawaited(check().catchError((_) => CatalogueCheckOutcome.failed));
    });
  }

  /// Fetch the manifest and, if it offers something newer, download and
  /// install it. Safe to call repeatedly; rate-limited by [_minCheckInterval]
  /// and by a backoff after failures.
  Future<CatalogueCheckOutcome> check({bool force = false}) async {
    if (kIsWeb) return CatalogueCheckOutcome.skipped;
    if (_checking) return CatalogueCheckOutcome.skipped;
    _checking = true;
    HttpClient? client;
    try {
      final dir = await _storageDir();
      final state = await _readState(dir);
      if (!force && !_dueForCheck(state)) return CatalogueCheckOutcome.skipped;

      client = (httpClientFactory ?? HttpClient.new)();
      client.connectionTimeout = const Duration(seconds: 10);

      final manifestRaw =
          await _getText('$baseUrl/manifest.json', client, _manifestTimeout);
      if (manifestRaw == null) {
        await _writeState(dir, state..['failCount'] = _failCount(state) + 1);
        return CatalogueCheckOutcome.failed;
      }

      final manifest = CatalogueManifest.tryParse(manifestRaw);
      // Record the successful reach even when the manifest is unusable — the
      // server answered, so hammering it again in a minute helps nobody.
      state['lastCheckMs'] = DateTime.now().millisecondsSinceEpoch;
      state['failCount'] = 0;

      if (manifest == null ||
          manifest.schema != CatalogueManifest.supportedSchema) {
        await _writeState(dir, state);
        return CatalogueCheckOutcome.upToDate;
      }

      if (manifest.disabled) {
        await _writeState(dir, state);
        if (await _pointerFile(dir).exists()) {
          await _dropInstalled('withdrawn by the publisher');
          return CatalogueCheckOutcome.revoked;
        }
        return CatalogueCheckOutcome.upToDate;
      }

      // Too new for this binary, or no newer than the asset we already ship.
      if (manifest.minAppBuild > appBuild ||
          !_shouldTake(manifest.generation)) {
        await _writeState(dir, state);
        return CatalogueCheckOutcome.upToDate;
      }

      // Already installed.
      final installed = await _installedGeneration(dir);
      if (installed == manifest.generation) {
        await _writeState(dir, state);
        return CatalogueCheckOutcome.upToDate;
      }

      final ok = await _download(dir, manifest, client);
      await _writeState(dir, state);
      return ok ? CatalogueCheckOutcome.installed : CatalogueCheckOutcome.failed;
    } catch (_) {
      return CatalogueCheckOutcome.failed;
    } finally {
      // force:true so an in-flight 25MB body cannot hold the client open.
      if (httpClientFactory == null) {
        try {
          client?.close(force: true);
        } catch (_) {}
      }
      _checking = false;
    }
  }

  /// Streams the payload to disk, inflating and hashing as it goes, and only
  /// moves the pointer once the digest matches.
  ///
  /// Streaming rather than buffering matters at this size: holding the 6MB
  /// gzip and the 25MB result in memory at once, on a phone that is also
  /// holding the parsed catalogue, is how a background task turns into a
  /// foreground kill.
  Future<bool> _download(
      Directory dir, CatalogueManifest m, HttpClient client) async {
    final part = File(p.join(dir.path, 'catalogue-${m.generation}.part'));
    IOSink? sink;
    try {
      final uri = Uri.parse('$baseUrl/${m.path}');
      final req = await client.getUrl(uri).timeout(_payloadTimeout);
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final res = await req.close().timeout(_payloadTimeout);
      if (res.statusCode != 200) return false;

      final digest = AccumulatorSink<Digest>();
      final hasher = sha256.startChunkedConversion(digest);
      var written = 0;
      var overflowed = false;

      sink = part.openWrite();
      // `autoAddDeflate:false` is not a thing on the decoder; the guard is the
      // byte counter below, checked on every chunk, so a bomb is cut off at
      // the cap instead of after it.
      final inflated = res.transform(gzip.decoder);
      await for (final chunk in inflated.timeout(_payloadTimeout)) {
        written += chunk.length;
        if (written > m.bytes || written > CatalogueManifest.maxCatalogueBytes) {
          overflowed = true;
          break;
        }
        hasher.add(chunk);
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      hasher.close();

      if (overflowed || written != m.bytes) return false;
      if (digest.events.single.toString() != m.sha256) return false;

      // Verified. Publish it: rename into its final name, then rewrite the
      // pointer. The pointer is written last and atomically, so a crash
      // anywhere above leaves the previous catalogue live.
      final dest = _payloadFile(dir, m.generation);
      await part.rename(dest.path);
      await _writePointer(dir, m);
      await _sweep(dir, keepGeneration: m.generation);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
    }
  }

  Future<void> _writePointer(Directory dir, CatalogueManifest m) async {
    final tmp = File(p.join(dir.path, '$_pointerName.part'));
    final body = json.encode({
      'generation': m.generation,
      'bytes': m.bytes,
      'sha256': m.sha256,
      'installedAtMs': DateTime.now().millisecondsSinceEpoch,
    });
    await tmp.writeAsString(body, flush: true);
    await tmp.rename(_pointerFile(dir).path);
  }

  Future<int?> _installedGeneration(Directory dir) async {
    try {
      final ptr = _pointerFile(dir);
      if (!await ptr.exists()) return null;
      final j = json.decode(await ptr.readAsString());
      final g = (j is Map<String, dynamic>) ? j['generation'] : null;
      return g is int ? g : null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _getText(
      String url, HttpClient client, Duration timeout) async {
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
      final res = await req.close().timeout(timeout);
      if (res.statusCode != 200) return null;
      // A manifest is a few hundred bytes. Anything remotely large is not one,
      // and reading it would be the bug.
      final buf = <int>[];
      await for (final chunk in res.timeout(timeout)) {
        buf.addAll(chunk);
        if (buf.length > 64 * 1024) return null;
      }
      return utf8.decode(buf, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  int _failCount(Map<String, dynamic> state) {
    final v = state['failCount'];
    return v is int ? v : 0;
  }

  /// [_minCheckInterval] between checks, doubling per consecutive failure up
  /// to a day. A device stuck behind a captive portal backs off instead of
  /// retrying a 25MB download on every interval forever.
  bool _dueForCheck(Map<String, dynamic> state) {
    final last = state['lastCheckMs'];
    if (last is! int) return true;
    final fails = _failCount(state).clamp(0, 3);
    final wait = _minCheckInterval * (1 << fails);
    final capped = wait > const Duration(hours: 24)
        ? const Duration(hours: 24)
        : wait;
    final elapsed = DateTime.now().millisecondsSinceEpoch - last;
    // A clock that jumped backwards would otherwise wedge checks off forever.
    if (elapsed < 0) return true;
    return elapsed >= capped.inMilliseconds;
  }

  Future<Map<String, dynamic>> _readState(Directory dir) async {
    try {
      final f = _stateFile(dir);
      if (!await f.exists()) return <String, dynamic>{};
      final j = json.decode(await f.readAsString());
      return j is Map<String, dynamic> ? j : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _writeState(Directory dir, Map<String, dynamic> state) async {
    try {
      await _stateFile(dir).writeAsString(json.encode(state), flush: true);
    } catch (_) {}
  }
}
