import 'package:flutter/material.dart';

import '../widgets/doc_scaffold.dart';

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DocScaffold(
      title: 'Privacy',
      children: [
        docNote('Last updated: August 2026'),
        docBody(
            'Qbit is designed to respect your privacy. You can learn without an '
            'account, your data is never sold, and there are no third-party '
            'advertising trackers in the app.'),
        docHeading('What we store'),
        docBody(
            'On your device: your learning progress (which words you have seen, '
            'streaks, and spaced-repetition schedule) and your app settings. '
            'This stays on your device unless you choose to sign in.'),
        docBody(
            'If you sign in (Apple or Google): a Qbit account is created with a '
            'unique ID and the email associated with that sign-in, and a copy '
            'of your progress and your Pro status is stored on our secure '
            'backend so it survives reinstalls and syncs across your devices.'),
        docHeading('What we do NOT do'),
        docBody(
            'We do not sell or rent your data. We do not show third-party ads. '
            'We do not embed advertising or social trackers. We do not access '
            'your contacts, photos, or location.'),
        docHeading('Voice and notifications'),
        docBody(
            'Word pronunciation uses your device text-to-speech and is '
            'processed on-device. Daily reminders are scheduled locally on your '
            'device; we do not send push messages from a server.'),
        docHeading('Your choices'),
        docBody(
            'Play fully offline and account-free to keep everything local. Sign '
            'out at any time to stop syncing. You can request deletion of your '
            'account and its synced data by contacting support@codeascent.app; '
            'in-app account deletion is on the roadmap.'),
        docHeading('Children'),
        docBody(
            'Qbit is not directed to children under 13, and we do not knowingly '
            'collect data from them.'),
        docHeading('Changes & contact'),
        docBody(
            'If this policy changes, we will update the date above and note it '
            'in the app changelog. Questions: support@codeascent.app.'),
      ],
    );
  }
}
