import 'package:flutter/material.dart';

import '../widgets/doc_scaffold.dart';

class SecurityScreen extends StatelessWidget {
  const SecurityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DocScaffold(
      title: 'Security',
      children: [
        docBody(
            'Qulex is built local-first, and the cloud layer is designed so that '
            'you — and only you — can reach your data.'),
        docHeading('In transit'),
        docBody(
            'All communication with our backend uses encrypted HTTPS/TLS '
            'connections.'),
        docHeading('Access control'),
        docBody(
            'Your synced progress and Pro status are protected by row-level '
            'security: the backend enforces that each signed-in user can read '
            'and write only their own rows. Your Pro entitlement is verified '
            'server-side, so it cannot be spoofed on the device.'),
        docHeading('Sign-in'),
        docBody(
            'Sign-in uses Apple and Google. Qulex never sees or stores a '
            'password — authentication is handled by the provider, and we '
            'receive only a secure token and your basic profile.'),
        docHeading('Local-first resilience'),
        docBody(
            'Your progress is saved on-device first. A dropped connection or a '
            'failed sync never loses local progress; changes reconcile safely '
            'the next time you are online, and a known/mastered word never '
            'silently reappears.'),
        docHeading('Your controls'),
        docBody(
            'Signing out removes Pro from the device until you sign back in '
            '(your entitlement is tied to your account, not the handset). You '
            'can request full deletion of your account and data at any time.'),
        docHeading('Reporting an issue'),
        docBody(
            'Found a security concern? Email security@codeascent.app and we '
            'will respond promptly.'),
      ],
    );
  }
}
