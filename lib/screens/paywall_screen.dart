import 'package:flutter/material.dart';
import '../l10n/strings.dart';
import '../services/sync_service.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/wordmark.dart';

/// Qbit Pro paywall — the monetization ladder.
///
/// Payment backend note: prices are shown statically here. On a mobile build,
/// wire RevenueCat's `purchases_flutter` in a PurchaseService: init with the
/// project's public SDK key, fetch the "default" offering, map its packages to
/// these tiers, and on tap call `Purchases.purchasePackage(...)`. Drive
/// `appState.setPro(...)` from the "pro" entitlement in the returned
/// CustomerInfo. (The SDK is not web-friendly, so it's intentionally not wired
/// into the web dev build.) The "Unlock (test)" button below flips Pro locally
/// so gated features can be exercised now.
class PaywallScreen extends StatelessWidget {
  const PaywallScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final locale = appState.locale;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Wordmark(size: 22),
                const SizedBox(width: 9),
                Text('PRO',
                    style: QType.mono(size: 14, color: QColors.coral, spacing: 3)),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close, color: QColors.muted),
                ),
              ]),
              const SizedBox(height: 8),
              Text(Strings.t(locale, 'proTagline'),
                  style: QType.serif(size: 26, color: QColors.cream, height: 1.2)),
              const SizedBox(height: 10),
              Text(Strings.t(locale, 'proFeatures'),
                  style: QType.sans(size: 13.5, color: QColors.muted, height: 1.5)),
              const SizedBox(height: 24),
              _Plan(
                title: Strings.t(locale, 'planLifetime'),
                price: '\$89.99',
                sub: Strings.t(locale, 'oneTime'),
                badge: Strings.t(locale, 'bestValue'),
                hero: true,
                locale: locale,
                onChoose: () => _notConnected(context, locale),
              ),
              const SizedBox(height: 10),
              _Plan(
                title: Strings.t(locale, 'planYearly'),
                price: '\$34.99',
                sub: Strings.t(locale, 'perYr'),
                locale: locale,
                onChoose: () => _notConnected(context, locale),
              ),
              const SizedBox(height: 10),
              _Plan(
                title: Strings.t(locale, 'planMonthly'),
                price: '\$6.99',
                sub: Strings.t(locale, 'perMo'),
                locale: locale,
                onChoose: () => _notConnected(context, locale),
              ),
              const SizedBox(height: 10),
              _Plan(
                title: Strings.t(locale, 'planHardship'),
                price: '\$1.99',
                sub: Strings.t(locale, 'perMo'),
                faint: true,
                locale: locale,
                onChoose: () => _notConnected(context, locale),
              ),
              const SizedBox(height: 18),
              Center(
                child: TextButton(
                  onPressed: () => _notConnected(context, locale),
                  child: Text(Strings.t(locale, 'restore').toUpperCase(),
                      style: QType.mono(size: 11, color: QColors.dim, spacing: 1.5)),
                ),
              ),
              const SizedBox(height: 2),
              // Local test unlock so gated modes can be exercised pre-store-setup.
              Center(
                child: AnimatedBuilder(
                  animation: appState,
                  builder: (_, __) => OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: QColors.rule),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6)),
                    ),
                    onPressed: () async {
                      await appState.setPro(!appState.isPro);
                      // Mirror the entitlement to the cloud so it survives a
                      // reinstall (no-op when signed out / backend unset).
                      await SyncService.instance.pushEntitlement(appState.isPro);
                      if (context.mounted && appState.isPro) {
                        Navigator.of(context).maybePop();
                      }
                    },
                    child: Text(
                        appState.isPro
                            ? 'PRO ✓'
                            : Strings.t(locale, 'unlockTest').toUpperCase(),
                        style: QType.mono(
                            size: 11,
                            color: appState.isPro ? QColors.coral : QColors.muted,
                            spacing: 1.5)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _notConnected(BuildContext context, String locale) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(Strings.t(locale, 'notConnected'),
          style: QType.mono(size: 12, color: QColors.cream)),
      backgroundColor: const Color(0xFF14141A),
      duration: const Duration(seconds: 3),
    ));
  }
}

class _Plan extends StatelessWidget {
  final String title, price, sub, locale;
  final String? badge;
  final bool hero, faint;
  final VoidCallback onChoose;
  const _Plan({
    required this.title,
    required this.price,
    required this.sub,
    required this.locale,
    required this.onChoose,
    this.badge,
    this.hero = false,
    this.faint = false,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: faint ? 0.7 : 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onChoose,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 15, 14, 15),
          decoration: BoxDecoration(
            color: hero ? QColors.coral.withOpacity(0.08) : QColors.panel,
            border: Border.all(color: hero ? QColors.coral : QColors.rule),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(title, style: QType.serif(size: 18, color: QColors.cream)),
                  if (badge != null) ...[
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                          color: QColors.coral,
                          borderRadius: BorderRadius.circular(4)),
                      child: Text(badge!.toUpperCase(),
                          style: QType.mono(
                              size: 8.5, color: const Color(0xFF160603), spacing: 1)),
                    ),
                  ],
                ]),
                const SizedBox(height: 2),
                Text(sub,
                    style: QType.mono(size: 10.5, color: QColors.dim, spacing: 1)),
              ]),
            ),
            Text(price, style: QType.serif(size: 22, color: QColors.coral)),
          ]),
        ),
      ),
    );
  }
}
