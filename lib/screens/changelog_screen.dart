import 'package:flutter/material.dart';

import '../widgets/doc_scaffold.dart';

/// A public changelog — WordUp's most-cited failing was silent, feature-removing
/// updates. Qulex keeps this visible and honest.
class ChangelogScreen extends StatelessWidget {
  const ChangelogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DocScaffold(
      title: "What's new",
      children: [
        docHeading('0.1.0 — beta'),
        docNote('The first Qulex.'),
        docBody(
            '• 2,200+ words across English, Spanish, Portuguese, Italian, and '
            'French — every word with a definition and an example sentence.\n'
            '• Spaced repetition that brings words back right before you forget '
            'them, plus a daily challenge and streaks.\n'
            '• Three ways to play: Classic, Reverse, and Listen.\n'
            '• Cloud sync so your progress and Pro survive a reinstall.\n'
            '• Daily word reminders that surface a real word from your pile.\n'
            '• Learner controls: set new-words-per-day and review intensity, '
            'mark words as known, and re-surface mastered words.\n'
            '• A 2-minute placement quiz that starts you at the right level.\n'
            '• Report a question if anything looks wrong.'),
        docHeading('Our promise'),
        docBody(
            'The core learning loop is free forever, and we never remove a mode '
            'you rely on. Every change ships here.'),
      ],
    );
  }
}
