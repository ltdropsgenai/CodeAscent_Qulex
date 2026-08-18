import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/voice.dart';
import '../widgets/doc_scaffold.dart';

/// App version — bump alongside pubspec. Kept as a const to avoid a
/// package_info dependency in the base.
const String kQulexVersion = '0.1.0 (beta)';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DocScaffold(
      title: 'About',
      children: [
        docNote('Qulex · Version $kQulexVersion · by CodeAscent'),
        docBody(
            'Qulex is a fast, gamified way to build real vocabulary. You play '
            'short rounds, meet words in context, and a spaced-repetition '
            'system brings each word back exactly when you are about to forget '
            'it — so learning sticks without feeling like a chore.'),
        docHeading('Built to be different'),
        docBody(
            'Qulex is multilingual from day one: word meanings are shown in your '
            'own language across English, Spanish, Portuguese, Italian, and '
            'French, with more to come. Every word ships with a clear '
            'definition and a natural example sentence, and answer choices are '
            'checked so the right answer is never obvious from its length.'),
        docHeading('Your learning, your control'),
        docBody(
            'You choose how many new words to meet each day and how intense '
            'reviews are. You can mark a word as known to stop seeing it, and '
            'bring mastered words back whenever you want. Progress is saved on '
            'your device and, if you sign in, synced securely across your '
            'devices.'),
        docHeading('Credits'),
        docBody(
            'Type: Space Mono, Spectral, and Inter. Natural voices by '
            'ElevenLabs. Built with Flutter.'),
        // Audio diagnostics, debug builds only. Every speak() records how it
        // was served — cloud voice, device fallback, or superseded — with the
        // time it took. This panel is what proved the client believed playback
        // had succeeded while the audio was silent, which moved the search off
        // the client and onto the Edge Function. Worth keeping for the next
        // time narration misbehaves; not worth showing a learner.
        if (kDebugMode) ...[
          docHeading('Audio diagnostics'),
          docNote(Voice.instance.diagnostics.isEmpty
              ? 'No audio attempts yet this session. Play a round, then come back.'
              : Voice.instance.diagnostics.join('\n')),
        ],
        docHeading('Contact'),
        docBody(
            'Questions, ideas, or bug reports are welcome at '
            'support@codeascent.app. We keep a public changelog and act on '
            'feedback — the roadmap is shaped by players.'),
      ],
    );
  }
}
