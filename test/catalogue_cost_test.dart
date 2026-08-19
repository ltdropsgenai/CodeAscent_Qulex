import 'package:flutter_test/flutter_test.dart';
import 'package:qulex/data/word_repository.dart';

/// Guards the launch experience.
///
/// The catalogue is ~24MB of JSON. Decoding it inline blocks the main isolate
/// for about a second, which is what made the title sequence appear to skip:
/// no frames render during the block, but the AnimationController and the
/// auto-advance Timer keep counting real time, so the intro "played" to a
/// frozen screen and then advanced instantly.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loadAll() returns the whole catalogue', () async {
    final sw = Stopwatch()..start();
    final words = await WordRepository().loadAll();
    sw.stop();
    // ignore: avoid_print
    print('  >> loadAll(): ${sw.elapsedMilliseconds} ms, ${words.length} words '
        '(decoded off the main isolate)');
    expect(words.length, greaterThan(16000));
    expect(words.first.word, isNotEmpty);
    expect(words.first.gloss, isNotEmpty);
  });
}
