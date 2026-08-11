import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'data/word_repository.dart';
import 'screens/home_screen.dart';
import 'screens/intro_screen.dart';
import 'services/auth_service.dart';
import 'services/notification_service.dart';
import 'services/supabase_config.dart';
import 'services/widget_service.dart';
import 'state/app_state.dart';
import 'theme.dart';
import 'widgets/app_background.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Reliability: never show the raw red error screen. Replace a build-time
  // failure with a calm branded panel so a single bad frame can't wreck a
  // session.
  ErrorWidget.builder = (details) => const _ErrorFallback();
  await appState.load();
  // Bring up the cloud-sync backend if configured; fall back to local-only if
  // initialization fails so the app always launches.
  if (SupabaseConfig.isConfigured) {
    try {
      await Supabase.initialize(
        url: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
      );
      await AuthService.instance.init();
    } catch (_) {/* run local-first without sync */}
  }
  // Prepare local notifications (no-op on web/desktop). Scheduling happens from
  // the home screen once words + progress are loaded.
  await NotificationService.instance.init();
  await WidgetService.instance.init();
  runApp(const QbitApp());
}

class QbitApp extends StatelessWidget {
  const QbitApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Qbit',
      debugShowCheckedModeBanner: false,
      theme: buildQbitTheme(),
      // Constrain to a phone-width column so desktop web previews look right;
      // on a real phone the column is simply full width.
      builder: (context, child) => ColoredBox(
        color: const Color(0xFF040405),
        // Responsive column: full width on a phone, capped + centered on
        // tablets / landscape so the layout never stretches or overflows.
        child: LayoutBuilder(
          builder: (ctx, cons) {
            final w = cons.maxWidth < 460 ? cons.maxWidth : 460.0;
            return Center(
              child: ClipRect(
                child: SizedBox(
                  width: w,
                  // One continuous animated backdrop behind every route.
                  child: Stack(
                    children: [
                      const AppBackground(dim: false),
                      if (child != null) Positioned.fill(child: child),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
      home: appState.seenIntro
          ? HomeScreen(repository: WordRepository())
          : IntroScreen(repository: WordRepository()),
    );
  }
}

/// Calm fallback shown in place of any widget that throws during build.
class _ErrorFallback extends StatelessWidget {
  const _ErrorFallback();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF07070A),
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(
            'Something hiccuped here.\nYour progress is safe — go back and try again.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0x8FFFFFFF),
              fontSize: 15,
              height: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}
