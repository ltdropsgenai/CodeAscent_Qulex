/// Backend configuration for Qulex cloud sync.
///
/// Defaults point at the Qulex Supabase project. They can be overridden at build
/// time without editing source:
///   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
///
/// The publishable key below is safe to ship in the client (it only grants what
/// Row-Level Security allows — each signed-in user sees only their own rows).
class SupabaseConfig {
  static const url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://fzhguqoodojugeuyosnj.supabase.co',
  );

  // Legacy JWT anon key — universally accepted by supabase_flutter and safe to
  // ship (RLS restricts every signed-in user to their own rows). The newer
  // sb_publishable_... key works too on recent SDKs; this one avoids version risk.
  static const anonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZ6aGd1cW9vZG9qdWdldXlvc25qIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYzMTE1MTUsImV4cCI6MjEwMTg4NzUxNX0.j028Mj6fKsw-9jJugUqNGMgMXWrWSu5iTpu3Dsk7JrA',
  );

  /// When false, the app runs fully local-first and hides all sign-in UI.
  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;

  /// OAuth redirect target. On web this is the running app origin; on mobile it
  /// must match the deep link registered in the native project AND in the
  /// Supabase dashboard (Authentication → URL Configuration).
  static const oauthRedirect = String.fromEnvironment(
    'QBIT_OAUTH_REDIRECT',
    defaultValue: 'io.codeascent.qbit://login-callback',
  );
}
