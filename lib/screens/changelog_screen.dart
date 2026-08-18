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
        docHeading('August 2026 — beta updates'),
        docNote('Everything below is already in the build you are running.'),
        docBody(
            '• Voice narration fixed. Words and definitions were being read '
            'with parts missing, or silently skipped altogether. The cause was '
            'a faulty pronunciation dictionary on our side; it has been rebuilt '
            'and every one of its 10,000+ entries is now spoken and checked '
            'before it ships.\n'
            '• Difficulty you choose: auto, easy, medium, or hard — so a '
            'beginner and an advanced learner no longer get the same words.\n'
            '• Spelling mode: hear the word, type it.\n'
            '• Exam practice split properly into SAT, GRE, and IELTS, each with '
            'its own word pool, plus an academic track built on the Academic '
            'Word List.\n'
            '• Accented answers now accepted — typing "saute" for "sauté" is '
            'no longer marked wrong.\n'
            '• Fixed a bug where tapping "Explain this" could push the '
            'continue button off-screen and strand you mid-round.'),
        docHeading('0.1.0 — first beta'),
        docBody(
            '• 16,800+ words across English, Spanish, Portuguese, Italian, and '
            'French — every word with a definition and an example sentence.\n'
            '• Six ways to play: Classic, Reverse, Listen, Spelling, the daily '
            'challenge, and untimed Review.\n'
            '• Spaced repetition that brings words back right before you forget '
            'them, plus streaks.\n'
            '• Cloud sync so your progress and Pro survive a reinstall.\n'
            '• Daily word reminders that surface a real word from your pile, '
            'and a home-screen widget on Android.\n'
            '• Your own sets: build a deck by hand or paste a Quizlet or Anki '
            'export.\n'
            '• Learner controls: set new-words-per-day and review intensity, '
            'mark words as known, and re-surface mastered words.\n'
            '• A 2-minute placement quiz that starts you at the right level.\n'
            '• Report a question if anything looks wrong.'),
        docHeading('Our promise'),
        docBody(
            'The core learning loop is free forever, and we never remove a mode '
            'you rely on. Every change ships here — including the ones that '
            'were our fault.'),
      ],
    );
  }
}
