import 'package:flutter_test/flutter_test.dart';
import 'package:qulex/services/heteronyms.dart';

/// Regression tests for sense-aware TTS respelling.
///
/// The bug these exist to prevent: part of speech is only a proxy for word
/// sense, and where both readings of a heteronym share a POS, a byPos rule
/// produces a confident WRONG answer rather than a miss. That shipped — the
/// live entry w_lead ("identified potential sales contact") was spoken as the
/// metal on every play, because the table mapped noun -> "led".
void main() {
  group('live regressions', () {
    test('w_lead is a sales lead, not the metal', () {
      expect(ttsRespell('lead', headword: 'lead', headwordPos: 'noun'), 'leed');
      expect(
        ttsRespell('lead', headword: 'lead', headwordPos: 'noun', headwordSay: 'leed'),
        'leed',
      );
    });

    test('wound: both the injury and "was wounded" are woond', () {
      expect(ttsRespell('wound', headword: 'wound', headwordPos: 'noun'), 'woond');
      expect(ttsRespell('wound', headword: 'wound', headwordPos: 'verb'), 'woond');
    });

    test('past-tense-of-wind is reachable only via an explicit override', () {
      expect(
        ttsRespell('wound', headword: 'wound', headwordPos: 'verb', headwordSay: 'wownd'),
        'wownd',
      );
    });
  });

  group('byPos rules that remain sound', () {
    test('wind', () {
      expect(ttsRespell('wind', headword: 'wind', headwordPos: 'verb'), 'wined');
      expect(ttsRespell('wind'), 'winned');
    });
    test('tear', () {
      expect(ttsRespell('tear', headword: 'tear', headwordPos: 'verb'), 'tare');
    });
    test('close', () {
      expect(ttsRespell('close', headword: 'close', headwordPos: 'verb'), 'klohz');
    });
    test('minute', () {
      expect(ttsRespell('minute', headword: 'minute', headwordPos: 'adjective'), 'mynoot');
    });
  });

  group('per-entry override', () {
    test('beats a byPos rule', () {
      expect(
        ttsRespell('wind', headword: 'wind', headwordPos: 'verb', headwordSay: 'winned'),
        'winned',
      );
    });

    test('works for words absent from the table', () {
      expect(
        ttsRespell('gaol', headword: 'gaol', headwordPos: 'noun', headwordSay: 'jail'),
        'jail',
      );
    });

    test('an empty override falls through rather than blanking the word', () {
      expect(
        ttsRespell('wind', headword: 'wind', headwordPos: 'verb', headwordSay: ''),
        'wined',
      );
    });
  });

  group('sentence handling', () {
    test('override applies to the headword token inside a sentence', () {
      expect(
        ttsRespell('The lead was warm.',
            headword: 'lead', headwordPos: 'noun', headwordSay: 'leed'),
        'The leed was warm.',
      );
    });

    test('non-headword heteronyms fall back to the generic default', () {
      expect(
        ttsRespell('She had a minute to read.',
            headword: 'lead', headwordPos: 'noun', headwordSay: 'leed'),
        'She had a minit to reed.',
      );
    });

    test('sentence-initial capitalization is preserved', () {
      expect(
        ttsRespell('Lead the way.',
            headword: 'lead', headwordPos: 'noun', headwordSay: 'leed'),
        'Leed the way.',
      );
    });

    test('text with no heteronyms is returned untouched', () {
      const s = 'She always locks the door at night.';
      expect(ttsRespell(s), s);
    });
  });
}
