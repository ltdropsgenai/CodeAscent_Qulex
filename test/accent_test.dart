import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qulex/state/app_state.dart';

/// The accent setting, and the two ways it can quietly do the wrong thing.
///
/// The accent is not a cosmetic preference. The voice id is part of the tts
/// cache key on the server AND part of the clip path on the device, so this
/// one string decides which of two disjoint caches every request lands in.
/// Two failures follow from that, and neither is visible by using the app for
/// a minute:
///
///   * An unrecognised value stored here would be sent to the tts function,
///     which resolves unknown accents to its default. The learner would then
///     hear the US voice while the UI showed their choice — a setting that
///     looks applied and is not.
///   * A value that fails to persist means the accent silently reverts on the
///     next launch, after the learner has already re-warmed a cache for it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults to the voice every existing clip was made with', () async {
    final s = AppState();
    await s.load();
    expect(s.accent, 'us',
        reason: 'every cached clip predates accents and was made with the US '
            'voice; defaulting to anything else strands all of them');
  });

  test('a chosen accent survives a restart', () async {
    final s = AppState();
    await s.load();
    await s.setAccent('uk');
    expect(s.accent, 'uk');

    final reloaded = AppState();
    await reloaded.load();
    expect(reloaded.accent, 'uk',
        reason: 'the accent did not persist — a learner who re-warmed a UK '
            'cache would be back on the US voice next launch');
  });

  test('an unsupported accent is refused, not stored', () async {
    final s = AppState();
    await s.load();
    await s.setAccent('au');
    expect(s.accent, 'us',
        reason: 'the tts function falls back to its default for an accent it '
            'does not know, so storing one here shows the learner a setting '
            'that is not in force');
  });

  test('the client offers exactly the accents the server routes', () {
    // tts/index.ts: VOICE_BY_ACCENT = { us, uk }. These two lists are compiled
    // in different languages and deployed on different days, and nothing else
    // compares them. Adding a voice on one side only is a silent no-op.
    expect(AppState.accents, ['us', 'uk']);
  });

  test('setting the accent it already has does not churn storage', () async {
    final s = AppState();
    await s.load();
    var notified = 0;
    s.addListener(() => notified++);
    await s.setAccent('us');
    expect(notified, 0);
  });
}
