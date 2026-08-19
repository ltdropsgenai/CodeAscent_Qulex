import 'package:flutter/material.dart';
import '../data/word_repository.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import '../widgets/wordmark.dart';
import 'handoff_screen.dart';

/// Qulex's differentiators, front and center. On first launch this is gated
/// behind the animated [IntroScreen] and shown once (`appState.seenIntro`),
/// then never again automatically — but it stays reachable any time from
/// Settings → About & legal → Replay welcome intro (pass [fromSettings]:
/// true so the CTA just closes back to Settings instead of relaunching Home).
class SplashScreen extends StatelessWidget {
  final WordRepository? repository;
  final bool fromSettings;
  const SplashScreen({super.key, this.repository, this.fromSettings = false});

  Future<void> _enter(BuildContext context) async {
    if (fromSettings) {
      if (context.mounted) Navigator.of(context).maybePop();
      return;
    }
    await appState.markIntroSeen();
    if (!context.mounted) return;
    // `repository!` used to be a force-unwrap here. It happened to be safe
    // because the only caller that reaches this branch always supplies one and
    // the Settings caller returns above — but that is a property of the call
    // sites, not of this method, and it is one refactor away from a crash on
    // the very first screen a new user sees. Build our own if we weren't given
    // one; WordRepository is stateless.
    final repo = repository ?? WordRepository();
    // Via the handoff, same as the returning-user path — a first run should
    // not be the one launch that cuts straight to a full dashboard.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => HandoffScreen(repository: repo)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locale = appState.locale;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Wordmark(size: 34),
                if (fromSettings) ...[
                  const Spacer(),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).maybePop(),
                    child: const Icon(Icons.close, color: QColors.muted),
                  ),
                ],
              ]),
              const Spacer(),
              Text(Strings.t(locale, 'splashHeadline'),
                  style: QType.serif(size: 34, weight: FontWeight.w600, color: QColors.cream, height: 1.12)),
              const SizedBox(height: 12),
              Text(Strings.t(locale, 'splashSub'),
                  style: QType.sans(size: 14.5, color: QColors.muted, height: 1.4)),
              const SizedBox(height: 28),
              _Point(icon: Icons.autorenew, titleKey: 'splashPoint1Title', bodyKey: 'splashPoint1Body', locale: locale),
              _Point(icon: Icons.translate, titleKey: 'splashPoint2Title', bodyKey: 'splashPoint2Body', locale: locale),
              _Point(icon: Icons.auto_stories_outlined, titleKey: 'splashPoint3Title', bodyKey: 'splashPoint3Body', locale: locale),
              _Point(icon: Icons.bolt, titleKey: 'splashPoint4Title', bodyKey: 'splashPoint4Body', locale: locale),
              _Point(icon: Icons.verified_outlined, titleKey: 'splashPoint5Title', bodyKey: 'splashPoint5Body', locale: locale, last: true),
              const Spacer(flex: 2),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: QColors.coral,
                    foregroundColor: const Color(0xFF160603),
                    padding: const EdgeInsets.symmetric(vertical: 17),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kQRadius)),
                  ),
                  onPressed: () => _enter(context),
                  child: Text(Strings.t(locale, 'splashCta').toUpperCase(),
                      style: QType.mono(size: 13, color: const Color(0xFF160603), spacing: 2)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Point extends StatelessWidget {
  final IconData icon;
  final String titleKey;
  final String bodyKey;
  final String locale;
  final bool last;
  const _Point({
    required this.icon,
    required this.titleKey,
    required this.bodyKey,
    required this.locale,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: QColors.rule),
              borderRadius: BorderRadius.circular(kQRadius),
            ),
            child: Icon(icon, size: 17, color: QColors.coral),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(Strings.t(locale, titleKey),
                    style: QType.sans(size: 14.5, weight: FontWeight.w700, color: QColors.ink)),
                const SizedBox(height: 2),
                Text(Strings.t(locale, bodyKey),
                    style: QType.sans(size: 12.5, color: QColors.muted, height: 1.3)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
