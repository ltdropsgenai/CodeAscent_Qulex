import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

/// Guards the one CI mistake that breaks code push silently.
///
/// `shorebird patch` compares the patch's asset tree against the release it is
/// patching and refuses the whole patch if they differ —
/// UnpatchableChangeException. That is correct behaviour: a patch whose assets
/// do not match the shipped binary would be shipping a lie.
///
/// The trap is that any step which GENERATES assets has to run identically in
/// both workflows, and nothing enforces that. qbit-test ran
/// `flutter_launcher_icons`; qbit-patch did not; so every patch attempt failed
/// with an error that names the symptom (assets differ) and not the cause (one
/// workflow is missing a step). It cost a day and left code push unusable
/// through several releases.
///
/// This test reads the real codemagic.yaml and fails if they drift apart again.
/// It is deliberately about the CLASS of step rather than one hard-coded name,
/// so adding a future codegen step to qbit-test and forgetting qbit-patch also
/// goes red.
void main() {
  late YamlMap workflows;

  setUpAll(() {
    final f = File('codemagic.yaml');
    expect(f.existsSync(), isTrue,
        reason: 'run this from the package root; codemagic.yaml is the input');
    workflows = (loadYaml(f.readAsStringSync()) as YamlMap)['workflows'] as YamlMap;
  });

  List<String> stepNames(String workflow) {
    final wf = workflows[workflow] as YamlMap?;
    expect(wf, isNotNull, reason: '$workflow is missing from codemagic.yaml');
    return [
      for (final s in (wf!['scripts'] as YamlList))
        if (s is YamlMap && s['name'] != null) s['name'] as String
    ];
  }

  /// A step that writes files into the build tree before the binary is made.
  bool generatesAssets(String name) {
    final n = name.toLowerCase();
    return n.contains('icon') ||
        n.contains('generate') ||
        n.contains('build_runner') ||
        n.contains('codegen') ||
        n.contains('asset');
  }

  test('both Shorebird workflows exist', () {
    expect(workflows.keys, containsAll(<String>['qbit-test', 'qbit-patch']));
  });

  test('every asset-generating step in qbit-test also runs in qbit-patch', () {
    final release = stepNames('qbit-test');
    final patch = stepNames('qbit-patch');

    final generators = release.where(generatesAssets).toList();
    expect(generators, isNotEmpty,
        reason: 'qbit-test generates app icons; if that stopped being true, '
            'this guard has silently stopped guarding anything');

    final missing = generators.where((s) => !patch.contains(s)).toList();
    expect(missing, isEmpty,
        reason: 'qbit-patch is missing $missing. shorebird patch will throw '
            'UnpatchableChangeException, and the error will not tell you which '
            'step is absent — it will only say the assets differ.');
  });

  test('the icon step specifically is in both', () {
    // Named explicitly as well as by class, because this is the one that
    // actually broke and a rename should be a deliberate act.
    for (final wf in ['qbit-test', 'qbit-patch']) {
      expect(stepNames(wf), contains('Generate app icons'), reason: wf);
    }
  });

  test('both workflows run analysis and tests before building', () {
    for (final wf in ['qbit-test', 'qbit-patch']) {
      final names = stepNames(wf);
      expect(names, contains('Static analysis'), reason: wf);
      expect(names, contains('Unit tests'), reason: wf);
      // A patch that ships without running the suite is worse than no patch:
      // it reaches phones without an App Store review in the way.
      final testsAt = names.indexOf('Unit tests');
      final buildAt = names.indexWhere((n) =>
          n.startsWith('Build ') || n.startsWith('Patch '));
      expect(testsAt, lessThan(buildAt),
          reason: '$wf builds before it tests');
    }
  });

  test('shorebird.yaml is declared as a Flutter asset', () {
    // Build 37 failed on this exact line being absent, after an edit to
    // pubspec.yaml's dev_dependencies dropped it as collateral. The error
    // arrives from `shorebird release`, twelve steps into CI, on a machine
    // nobody is watching — six minutes to find out about a one-line omission
    // that `flutter test` and `flutter analyze` both pass straight over,
    // because nothing in a normal build cares whether that asset is declared.
    //
    // Guarded here rather than trusted, because the line reads like ordinary
    // asset housekeeping and gives no hint that removing it breaks releases.
    final shorebird = File('shorebird.yaml');
    if (!shorebird.existsSync()) {
      // No Shorebird in this checkout — nothing to guard. Stated explicitly so
      // a future removal of code push does not leave a mysteriously
      // always-passing test behind.
      return;
    }
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- shorebird.yaml'),
        reason: 'pubspec.yaml must list shorebird.yaml under flutter/assets or '
            '`shorebird release` refuses to build, and it will only tell you '
            'in CI');
  });

  test('no workflow declares an environment variable as an empty string', () {
    // One `RELEASE_VERSION: ""` invalidated the whole file and broke the
    // Start-build dialog for EVERY workflow, not just its own. API-triggered
    // builds skip that validator, which is why it went unnoticed.
    void walk(dynamic node, String path) {
      if (node is YamlMap) {
        node.forEach((k, v) {
          if (k == 'vars' && v is YamlMap) {
            v.forEach((name, value) {
              expect(value, isNot(''),
                  reason: '$path declares $name as an empty string');
            });
          }
          walk(v, '$path/$k');
        });
      } else if (node is YamlList) {
        for (var i = 0; i < node.length; i++) {
          walk(node[i], '$path[$i]');
        }
      }
    }
    walk(workflows, 'workflows');
  });
}
