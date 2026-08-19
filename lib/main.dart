import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'data/word_repository.dart';
import 'screens/intro_screen.dart';
import 'services/auth_service.dart';
import 'services/notification_service.dart';
import 'services/supabase_config.dart';
import 'services/voice.dart';
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
  // Claim the audio session before the first question rather than after the
  // first inaudible one — see Voice.warmUp().
  await Voice.instance.warmUp();
  await NotificationService.instance.init();
  await WidgetService.instance.init();
  runApp(const QulexApp());
}

class QulexApp extends StatelessWidget {
  const QulexApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Qulex',
      debugShowCheckedModeBanner: false,
      theme: buildQulexTheme(),
      // The app is a reading column, so its content is capped for line length.
      // What must NOT be capped is the backdrop: putting the photo inside the
      // column left an iPad showing a phone-width strip floating in flat grey,
      // which is the "no landscape, lots of blank space" complaint reviewers
      // make about WordUp. The backdrop now fills the display and the column
      // sits on top of it, so a large screen reads as deliberate.
      builder: (context, child) => ColoredBox(
        color: QColors.bg,
        child: LayoutBuilder(
          builder: (ctx, cons) {
            final w = _columnWidth(cons.maxWidth);
            final capped = w < cons.maxWidth;
            final gutter = (cons.maxWidth - w) / 2;
            return Stack(
              children: [
                // ONE backdrop, full-bleed. It used to live inside the column,
                // which left a wide display showing a phone-width strip in a
                // flat grey void - the "no landscape, lots of blank space"
                // complaint reviewers make about WordUp. It must stay a single
                // instance: AppBackground cross-fades eight photos on its own
                // timer, so two of them drift apart and show different scenes.
                const Positioned.fill(child: AppBackground(dim: false)),

                // Scrim the exposed gutters only, never the column, so the
                // reading area stays the brightest thing on screen.
                if (capped) ...[
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: gutter,
                    child: const IgnorePointer(
                      child: ColoredBox(color: Color(0x9904040A)),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    width: gutter,
                    child: const IgnorePointer(
                      child: ColoredBox(color: Color(0x9904040A)),
                    ),
                  ),
                ],

                Center(
                  child: SizedBox(
                    width: w,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        // Hairline edges only when inset, so the column reads
                        // as a deliberate panel rather than a cropped phone.
                        border: capped
                            ? const Border.symmetric(
                                vertical: BorderSide(color: QColors.rule))
                            : null,
                      ),
                      child: ClipRect(
                        child: child ?? const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
      // The title sequence plays on every cold start and routes onward
      // itself: a first run continues into the pitch, everyone else lands
      // straight on Home. See IntroScreen.
      home: IntroScreen(repository: WordRepository()),
    );
  }
}

/// Content width for the available display width.
///
/// Deliberately conservative. Every screen in the app was laid out against a
/// ~460pt column, so widening aggressively would risk stretching rows that
/// were never designed for it. These steps give a tablet a visibly roomier
/// column without re-tuning each screen, and the full-bleed backdrop behind
/// it does most of the work of making a big display look intentional.
double _columnWidth(double available) {
  if (available < 460) return available; // phone: edge to edge
  if (available < 900) return 460; // large phone, landscape phone
  if (available < 1200) return 540; // tablet portrait
  return 600; // tablet landscape, desktop web
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
