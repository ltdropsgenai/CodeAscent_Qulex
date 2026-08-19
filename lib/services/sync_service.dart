import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/progress_store.dart';
import '../state/app_state.dart';
import 'auth_service.dart';
import 'supabase_config.dart';

enum SyncResult { ok, skipped, error }

/// Bridges the local [ProgressStore] + [appState] entitlement with Supabase.
/// Local stays the source of truth; this pushes/pulls a mirror so a signed-in
/// user's progress and Pro status survive reinstalls and move across devices.
class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  ProgressStore? _store;

  /// Home screen registers its store instance so on-demand syncs can reach it.
  void attach(ProgressStore store) => _store = store;

  bool get _enabled => SupabaseConfig.isConfigured;
  SupabaseClient get _c => Supabase.instance.client;
  String? get _uid => AuthService.instance.user?.id;

  String _nowUtc() => DateTime.now().toUtc().toIso8601String();

  /// Full reconcile: pull remote → merge into local → push the union back, then
  /// reconcile the Pro entitlement. Safe to call on sign-in and on demand.
  Future<SyncResult> syncNow() async {
    final store = _store;
    final uid = _uid;
    if (!_enabled || store == null || uid == null) return SyncResult.skipped;
    try {
      final remote =
          await _c.from('progress').select().eq('user_id', uid).maybeSingle();
      if (remote != null &&
          (remote['words'] != null || remote['profile'] != null)) {
        await store.importState({
          'words': remote['words'] ?? const {},
          'profile': remote['profile'] ?? const {},
        }, merge: true);
      }
      await pushProgress();
      await _reconcileEntitlement(uid);
      return SyncResult.ok;
    } catch (_) {
      return SyncResult.error;
    }
  }

  /// Upload the current local learning state (used after a match completes).
  Future<void> pushProgress() async {
    final store = _store;
    final uid = _uid;
    if (!_enabled || store == null || uid == null) return;
    final state = store.exportState();
    try {
      await _c.from('progress').upsert({
        'user_id': uid,
        'words': state['words'],
        'profile': state['profile'],
        'known': store.knownCount(),
        'streak': store.profile.streak,
        'vocab_rank': store.vocabRank(),
        'updated_at': _nowUtc(),
      });
    } catch (_) {/* best-effort; next full sync reconciles */}
  }

  /// Read the entitlement the SERVER believes in, and adopt it.
  ///
  /// This used to be a two-way reconcile that wrote `is_pro` back from the
  /// client, and the RLS policy allowed it: `entitlements_own` was ALL with
  /// `with_check (auth.uid() = user_id)`, so the row only had to be yours —
  /// nothing constrained the value. Anyone signed in could grant themselves
  /// Pro with a single REST call using the anon key that ships in the binary,
  /// and because the old rule was `remotePro || localPro` it stuck forever.
  ///
  /// The table is now client-readable only, written exclusively by a
  /// store-webhook function holding the service role. So the server is the
  /// authority and this just follows it.
  Future<void> _reconcileEntitlement(String uid) async {
    final row =
        await _c.from('entitlements').select().eq('user_id', uid).maybeSingle();
    final remotePro = (row?['is_pro'] as bool?) ?? false;
    if (remotePro != appState.isPro) await appState.setPro(remotePro);
  }
}
