import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../state/app_state.dart';
import 'supabase_config.dart';
import 'sync_service.dart';

/// Thin wrapper over Supabase Auth. Exposes the current user as a
/// ChangeNotifier so widgets can react via AnimatedBuilder, mirroring how the
/// rest of the app consumes `appState`.
///
/// Sign-in methods:
///  - Google / Apple via OAuth (the App Store path). These require the provider
///    to be configured in the Supabase dashboard (Authentication → Providers)
///    with your OAuth credentials + redirect URL. Until then they surface a
///    friendly error rather than crashing.
///  - Anonymous, for verifying the sync pipeline in dev. Requires "Allow
///    anonymous sign-ins" to be enabled once in the dashboard (Authentication →
///    Sign In / Providers). It creates a real auth user so RLS + tables work.
class AuthService extends ChangeNotifier {
  AuthService._();
  static final AuthService instance = AuthService._();

  // True only after Supabase.initialize + init() both succeed. Until then the
  // app runs local-only and every getter avoids touching Supabase.instance.
  bool _initialized = false;
  bool get ready => _initialized;

  /// Whether the backend is configured AND initialized (usable). When false the
  /// app is local-only and all sign-in UI hides.
  bool get enabled => SupabaseConfig.isConfigured && _initialized;

  SupabaseClient get _client => Supabase.instance.client;

  User? get user => enabled ? _client.auth.currentUser : null;
  bool get isSignedIn => user != null;
  bool get isAnonymous => user?.isAnonymous ?? false;
  String get label {
    final u = user;
    if (u == null) return '';
    if (u.isAnonymous) return 'Guest';
    return u.email ?? u.userMetadata?['name']?.toString() ?? 'Signed in';
  }

  /// Called by main() ONLY after Supabase.initialize succeeds. Wires the auth
  /// stream and marks the service usable.
  Future<void> init() async {
    _initialized = true;
    _client.auth.onAuthStateChange.listen((data) {
      notifyListeners();
      // On sign-in, reconcile progress + entitlement with the cloud. Safe if
      // the store isn't attached yet (returns skipped); the home screen also
      // fires an initial sync once its store is ready.
      if (data.session != null) SyncService.instance.syncNow();
    });
    notifyListeners();
  }

  Future<void> signInWithGoogle() => _oauth(OAuthProvider.google);
  Future<void> signInWithApple() => _oauth(OAuthProvider.apple);

  Future<void> _oauth(OAuthProvider provider) async {
    if (!enabled) throw const AuthFailure('Cloud sync is not configured.');
    try {
      await _client.auth.signInWithOAuth(
        provider,
        redirectTo: kIsWeb ? null : SupabaseConfig.oauthRedirect,
      );
      // The session arrives asynchronously via the redirect + onAuthStateChange.
    } on AuthException catch (e) {
      throw AuthFailure(_pretty(provider, e.message));
    } catch (e) {
      throw AuthFailure(_pretty(provider, e.toString()));
    }
  }

  /// Dev/testing path: instant account with no credentials. Needs anonymous
  /// sign-ins enabled once in the Supabase dashboard.
  Future<void> signInAnonymously() async {
    if (!enabled) throw const AuthFailure('Cloud sync is not configured.');
    try {
      await _client.auth.signInAnonymously();
    } on AuthException catch (e) {
      final msg = e.message.toLowerCase().contains('disabled')
          ? 'Anonymous sign-in is off. Enable it in Supabase → Authentication.'
          : e.message;
      throw AuthFailure(msg);
    }
  }

  Future<void> signOut() async {
    if (!enabled) return;
    await _client.auth.signOut();
    // Entitlement is account-bound; drop local Pro so it doesn't bleed into the
    // next account. A real purchase is restored on the next sign-in via sync.
    await appState.setPro(false);
    notifyListeners();
  }

  String _pretty(OAuthProvider p, String raw) {
    final name = p == OAuthProvider.google ? 'Google' : 'Apple';
    if (raw.toLowerCase().contains('provider') &&
        raw.toLowerCase().contains('not enabled')) {
      return '$name sign-in isn\'t configured yet. Add its OAuth keys in Supabase.';
    }
    return '$name sign-in failed: $raw';
  }
}

class AuthFailure implements Exception {
  final String message;
  const AuthFailure(this.message);
  @override
  String toString() => message;
}
