import 'package:flutter/material.dart';

import '../widgets/doc_scaffold.dart';

/// App version — bump alongside pubspec. Kept as a const to avoid a
/// package_info dependency in the base.
const String kQbitVersion = '0.1.0 (beta)';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DocScaffold(
      title: 'About',
      children: [
        docNote('Qbit · Version $kQbitVersion · by CodeAscent'),
        docBody(
            'Qbit is a fast, gamified way to build real vocabulary. You play '
            'short rounds, meet words in context, and a spaced-repetition '
            'system brings each word back exactly when you are about to forget '
            'it — so learning sticks without feeling like a chore.'),
        docHeading('Built to be different'),
        docBody(
            'Qbit is multilingual from day one: word meanings are shown in your '
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
        docHeading('Contact'),
        docBody(
            'Questions, ideas, or bug reports are welcome at '
            'support@codeascent.app. We keep a public changelog and act on '
            'feedback — the roadmap is shaped by players.'),
      ],
    );
  }
}
