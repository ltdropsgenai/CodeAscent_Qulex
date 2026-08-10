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

  /// Once-Pro-always-Pro: the effective entitlement is local OR remote, and we
  /// write it back wherever it's missing.
  Future<void> _reconcileEntitlement(String uid) async {
    final row =
        await _c.from('entitlements').select().eq('user_id', uid).maybeSingle();
    final remotePro = (row?['is_pro'] as bool?) ?? false;
    final localPro = appState.isPro;
    final effective = remotePro || localPro;
    if (effective != localPro) await appState.setPro(effective);
    if (effective != remotePro) {
      await _c.from('entitlements').upsert({
        'user_id': uid,
        'is_pro': effective,
        'source': 'client',
        'updated_at': _nowUtc(),
      });
    }
  }

  /// Push an entitlement change immediately (e.g. right after a purchase/test
  /// unlock) so it isn't lost if the app closes before the next full sync.
  Future<void> pushEntitlement(bool isPro) async {
    final uid = _uid;
    if (!_enabled || uid == null) return;
    try {
      await _c.from('entitlements').upsert({
        'user_id': uid,
        'is_pro': isPro,
        'source': 'client',
        'updated_at': _nowUtc(),
      });
    } catch (_) {/* best-effort; next full sync will reconcile */}
  }
}
