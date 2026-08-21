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
      // The default still applies to a headword with no POS and no `say` —
      // what changed is that it no longer applies to the word when it turns up
      // in somebody else's sentence.
      expect(ttsRespell('wind', headword: 'wind'), 'winned');
      expect(ttsRespell('wind'), 'wind');
    });
    test('tear', () {
      expect(ttsRespell('tear', headword: 'tear', headwordPos: 'verb'), 'tare');
    });
    test('close', () {
      // 'cloze' — a real English word — not the old 'klohz', which was
      // dictionary notation and was spoken as the nonsense token it is.
      expect(ttsRespell('close', headword: 'close', headwordPos: 'verb'), 'cloze');
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

    test('non-headword heteronyms are left exactly as written', () {
      // This used to assert the opposite — 'She had a minit to reed.' — and
      // that example passed only by luck: both guesses happen to be right in
      // THAT sentence. "he read the book" and "the bow of the ship" got the
      // same fixed defaults and came out wrong.
      expect(
        ttsRespell('She had a minute to read.',
            headword: 'lead', headwordPos: 'noun', headwordSay: 'leed'),
        'She had a minute to read.',
      );
    });

    test('the headword is still respelled inside its own sentence', () {
      // The gate is on identity, not position — the one token whose sense we
      // actually know must keep its pronunciation.
      expect(
        ttsRespell('Wind the clock and read on.',
            headword: 'wind', headwordPos: 'verb'),
        'Wined the clock and read on.',
      );
    });

    test('every sense of a non-headword survives untouched', () {
      // The six sentences that were listened to on 21 Aug 2026. Each one has
      // an unambiguous sense to a human reader and the model gets them right
      // from context; the old code overwrote all of them.
      const cases = [
        'Please close the gate behind you.',
        'A bond between close friends.',
        'He read the book yesterday.',
        'The bow of the ship.',
        'A lead pipe.',
        'A minute amount.',
      ];
      for (final c in cases) {
        expect(ttsRespell(c), c, reason: 'rewrote: $c');
      }
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
