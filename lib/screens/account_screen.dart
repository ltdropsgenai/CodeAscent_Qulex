import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../services/auth_service.dart';
import '../services/sync_service.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/wordmark.dart';

/// Sign-in + cloud-sync surface. Progress and Pro live locally first; signing
/// in mirrors them to the Qulex backend so they survive reinstalls and move
/// across devices.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on AuthFailure catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: QType.mono(size: 12, color: QColors.cream)),
      backgroundColor: const Color(0xFF14141A),
      duration: const Duration(seconds: 4),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final locale = appState.locale;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: AnimatedBuilder(
          animation: AuthService.instance,
          builder: (context, _) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Wordmark(size: 22),
                  const SizedBox(width: 9),
                  Text(Strings.t(locale, 'account').toUpperCase(),
                      style:
                          QType.mono(size: 14, color: QColors.coral, spacing: 3)),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close, color: QColors.muted),
                  ),
                ]),
                const SizedBox(height: 8),
                if (!AuthService.instance.enabled)
                  _localOnlyNote(locale)
                else if (AuthService.instance.isSignedIn)
                  _signedIn(locale)
                else
                  _signedOut(locale),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _localOnlyNote(String locale) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(Strings.t(locale, 'syncLocalOnly'),
            style: QType.sans(size: 13.5, color: QColors.muted, height: 1.5)),
      );

  Widget _signedIn(String locale) {
    final auth = AuthService.instance;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(Strings.t(locale, 'signedIn'),
          style: QType.serif(size: 26, color: QColors.cream, height: 1.2)),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: QColors.panel,
          border: Border.all(color: QColors.rule),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          Icon(auth.isAnonymous ? Icons.person_outline : Icons.cloud_done,
              color: QColors.coral, size: 22),
          const SizedBox(width: 13),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(auth.label,
                  style: QType.serif(size: 16, color: QColors.cream)),
              const SizedBox(height: 2),
              Text(
                  Strings.t(
                      locale, auth.isAnonymous ? 'guestNote' : 'syncedNote'),
                  style: QType.mono(size: 10, color: QColors.dim, spacing: 0.5)),
            ]),
          ),
          if (appState.isPro)
            Text('PRO',
                style: QType.mono(size: 11, color: QColors.coral, spacing: 2)),
        ]),
      ),
      const SizedBox(height: 14),
      _outlined(
        icon: Icons.sync,
        label: Strings.t(locale, 'syncNow'),
        onTap: _busy
            ? null
            : () => _run(() async {
                  final r = await SyncService.instance.syncNow();
                  _snack(Strings.t(
                      locale, r == SyncResult.ok ? 'syncOk' : 'syncFailed'));
                  if (mounted) setState(() {});
                }),
      ),
      if (auth.isAnonymous) ...[
        const SizedBox(height: 10),
        Text(Strings.t(locale, 'guestUpgradeHint'),
            style: QType.sans(size: 12.5, color: QColors.muted, height: 1.45)),
        const SizedBox(height: 10),
        _appleButton(locale),
        const SizedBox(height: 9),
        _googleButton(locale),
      ],
      const SizedBox(height: 16),
      Center(
        child: TextButton(
          onPressed: _busy ? null : () => _run(() => AuthService.instance.signOut()),
          child: Text(Strings.t(locale, 'signOut').toUpperCase(),
              style: QType.mono(size: 11, color: QColors.dim, spacing: 1.5)),
        ),
      ),
    ]);
  }

  Widget _signedOut(String locale) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(Strings.t(locale, 'saveProgress'),
          style: QType.serif(size: 26, color: QColors.cream, height: 1.2)),
      const SizedBox(height: 10),
      Text(Strings.t(locale, 'saveProgressSub'),
          style: QType.sans(size: 13.5, color: QColors.muted, height: 1.5)),
      const SizedBox(height: 22),
      _appleButton(locale),
      const SizedBox(height: 10),
      _googleButton(locale),
      const SizedBox(height: 18),
      Row(children: [
        Expanded(child: Container(height: 1, color: QColors.rule)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(Strings.t(locale, 'orTest').toUpperCase(),
              style: QType.mono(size: 9, color: QColors.dim, spacing: 1.5)),
        ),
        Expanded(child: Container(height: 1, color: QColors.rule)),
      ]),
      const SizedBox(height: 14),
      _outlined(
        icon: Icons.person_outline,
        label: Strings.t(locale, 'continueGuest'),
        onTap: _busy
            ? null
            : () => _run(() => AuthService.instance.signInAnonymously()),
      ),
      const SizedBox(height: 8),
      Text(Strings.t(locale, 'guestTestNote'),
          style: QType.mono(size: 9.5, color: QColors.dim, spacing: 0.3)),
    ]);
  }

  Widget _appleButton(String locale) => _AuthButton(
        bg: Colors.white,
        fg: const Color(0xFF0B0B0F),
        icon: Icons.apple,
        label: Strings.t(locale, 'continueApple'),
        onTap: _busy ? null : () => _run(() => AuthService.instance.signInWithApple()),
      );

  Widget _googleButton(String locale) => _AuthButton(
        bg: const Color(0xFF15151B),
        fg: QColors.cream,
        border: QColors.rule,
        iconWidget: Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
              color: Colors.white, shape: BoxShape.circle),
          child: Text('G',
              style: QType.serif(size: 12, color: Color(0xFF0B0B0F))),
        ),
        label: Strings.t(locale, 'continueGoogle'),
        onTap: _busy ? null : () => _run(() => AuthService.instance.signInWithGoogle()),
      );

  Widget _outlined(
          {required IconData icon,
          required String label,
          required VoidCallback? onTap}) =>
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: QColors.rule),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: onTap,
          icon: Icon(icon, size: 17, color: QColors.muted),
          label: Text(label.toUpperCase(),
              style: QType.mono(size: 11.5, color: QColors.muted, spacing: 1.5)),
        ),
      );
}

class _AuthButton extends StatelessWidget {
  final Color bg, fg;
  final Color? border;
  final IconData? icon;
  final Widget? iconWidget;
  final String label;
  final VoidCallback? onTap;
  const _AuthButton({
    required this.bg,
    required this.fg,
    required this.label,
    required this.onTap,
    this.icon,
    this.iconWidget,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: border != null
                ? BorderSide(color: border!)
                : BorderSide.none,
          ),
        ),
        onPressed: onTap,
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (iconWidget != null) iconWidget! else if (icon != null)
            Icon(icon, size: 19, color: fg),
          const SizedBox(width: 10),
          Text(label,
              style: QType.sans(size: 14, color: fg, weight: FontWeight.w600)),
        ]),
      ),
    );
  }
}
