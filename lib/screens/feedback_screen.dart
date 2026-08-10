import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/strings.dart';
import '../services/auth_service.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/wordmark.dart';
import 'about_screen.dart' show kQbitVersion;

/// Send feedback (bug or idea) to the Qbit backend. Requires a session (sign in,
/// or Continue as guest) because row-level security ties each note to its author.
class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  final TextEditingController _ctrl = TextEditingController();
  String _kind = 'idea';
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: QType.mono(size: 12, color: QColors.cream)),
      backgroundColor: const Color(0xFF14141A),
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _submit(String locale) async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) {
      _snack(Strings.t(locale, 'feedbackEmpty'));
      return;
    }
    final uid = AuthService.instance.user?.id;
    if (!AuthService.instance.enabled || uid == null) {
      _snack(Strings.t(locale, 'feedbackSignIn'));
      return;
    }
    setState(() => _busy = true);
    try {
      await Supabase.instance.client.from('feedback').insert({
        'user_id': uid,
        'kind': _kind,
        'message': text,
        'app_version': kQbitVersion,
      });
      _snack(Strings.t(locale, 'feedbackThanks'));
      if (mounted) Navigator.of(context).maybePop();
    } catch (_) {
      _snack(Strings.t(locale, 'syncFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
                Expanded(
                  child: Text(Strings.t(locale, 'sendFeedback').toUpperCase(),
                      style:
                          QType.mono(size: 14, color: QColors.coral, spacing: 3)),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close, color: QColors.muted),
                ),
              ]),
              const SizedBox(height: 10),
              Text(Strings.t(locale, 'feedbackHint'),
                  style: QType.sans(size: 13.5, color: QColors.muted, height: 1.5)),
              const SizedBox(height: 18),
              Row(children: [
                _kindChip(locale, 'idea', Icons.lightbulb_outline),
                const SizedBox(width: 8),
                _kindChip(locale, 'bug', Icons.bug_report_outlined),
              ]),
              const SizedBox(height: 14),
              Container(
                decoration: BoxDecoration(
                  color: QColors.panel,
                  border: Border.all(color: QColors.rule),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: TextField(
                  controller: _ctrl,
                  maxLines: 6,
                  maxLength: 1000,
                  style: QType.sans(size: 14, color: QColors.cream),
                  cursorColor: QColors.coral,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    counterStyle:
                        QType.mono(size: 9, color: QColors.dim, spacing: 0.5),
                    hintText: Strings.t(locale, 'feedbackPlaceholder'),
                    hintStyle: QType.sans(size: 14, color: QColors.dim),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: QColors.coral,
                    disabledBackgroundColor: QColors.coral.withOpacity(0.25),
                    foregroundColor: const Color(0xFF160603),
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6)),
                  ),
                  onPressed: _busy ? null : () => _submit(locale),
                  child: Text(Strings.t(locale, 'feedbackSend').toUpperCase(),
                      style: QType.mono(
                          size: 13, color: const Color(0xFF160603), spacing: 2)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kindChip(String locale, String kind, IconData icon) {
    final sel = _kind == kind;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _kind = kind),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: sel ? QColors.coral.withOpacity(0.12) : QColors.panel,
            border: Border.all(color: sel ? QColors.coral : QColors.rule),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 15, color: sel ? QColors.coral : QColors.muted),
            const SizedBox(width: 7),
            Text(
                Strings.t(locale, kind == 'bug' ? 'feedbackBug' : 'feedbackIdea')
                    .toUpperCase(),
                style: QType.mono(
                    size: 10,
                    color: sel ? QColors.coral : QColors.muted,
                    spacing: 1)),
          ]),
        ),
      ),
    );
  }
}
