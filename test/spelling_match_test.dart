import 'package:flutter_test/flutter_test.dart';
import 'package:qulex/game/spelling_match.dart';

/// Spelling mode asks the learner to hear a word and type it back. 77 of the
/// catalogue's headwords carry accents, and requiring them made those rounds a
/// test of phone-keyboard dexterity rather than spelling.
void main() {
  group('diacritics are accepted either way', () {
    test('French loanwords', () {
      expect(normalizeSpelling('saute'), normalizeSpelling('sauté'));
      expect(normalizeSpelling('entree'), normalizeSpelling('entrée'));
      expect(normalizeSpelling('developpe'), normalizeSpelling('développé'));
      expect(normalizeSpelling('fougere'), normalizeSpelling('fougère'));
      expect(normalizeSpelling('communique'), normalizeSpelling('communiqué'));
    });

    test('other Latin accents', () {
      expect(normalizeSpelling('jalapeno'), normalizeSpelling('jalapeño'));
      expect(normalizeSpelling('facade'), normalizeSpelling('façade'));
      expect(normalizeSpelling('naive'), normalizeSpelling('naïve'));
    });

    test('ligatures and eszett expand', () {
      expect(foldDiacritics('œuvre'), 'oeuvre');
      expect(foldDiacritics('æther'), 'aether');
      expect(foldDiacritics('straße'), 'strasse');
    });
  });

  group('existing behaviour is preserved', () {
    test('case and surrounding whitespace are ignored', () {
      expect(normalizeSpelling('  Batard '), normalizeSpelling('batard'));
    });

    test('internal whitespace is collapsed for multi-word entries', () {
      expect(normalizeSpelling('grand  jete'), normalizeSpelling('grand jeté'));
    });

    test('genuinely different spellings still differ', () {
      expect(normalizeSpelling('batard') == normalizeSpelling('bastard'), isFalse);
      expect(normalizeSpelling('saute') == normalizeSpelling('sauce'), isFalse);
    });

    test('unaccented words are untouched', () {
      expect(normalizeSpelling('abundant'), 'abundant');
    });
  });
}
