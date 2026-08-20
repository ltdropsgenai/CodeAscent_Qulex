import 'package:flutter/material.dart';

import '../a11y.dart';

import '../data/custom_set_store.dart';
import '../data/progress_store.dart';
import '../game/game_controller.dart';
import '../game/track.dart';
import '../l10n/strings.dart';
import '../models/custom_set.dart';
import '../models/word.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/wordmark.dart';
import 'game_screen.dart';
import 'set_editor_screen.dart';

/// "My sets" — list, create, import, play, and delete user study sets.
class SetsListScreen extends StatefulWidget {
  final List<Word> library;
  final ProgressStore store;
  const SetsListScreen({super.key, required this.library, required this.store});

  @override
  State<SetsListScreen> createState() => _SetsListScreenState();
}

class _SetsListScreenState extends State<SetsListScreen> {
  final CustomSetStore _setStore = CustomSetStore();
  late Future<void> _future;

  @override
  void initState() {
    super.initState();
    _future = _setStore.load();
  }

  Future<void> _openEditor([CustomSet? existing]) async {
    final saved = await Navigator.of(context).push<bool>(PageRouteBuilder(
      opaque: true,
      transitionDuration: A11y.duration(context, const Duration(milliseconds: 240)),
      pageBuilder: (_, __, ___) =>
          SetEditorScreen(existing: existing, setStore: _setStore),
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    ));
    if (saved == true && mounted) setState(() {});
  }

  void _play(CustomSet set) {
    final words = wordsFromSet(set,
        library: widget.library, locale: appState.locale);
    if (words.isEmpty) return;
    Navigator.of(context).push(PageRouteBuilder(
      transitionDuration: A11y.duration(context, const Duration(milliseconds: 300)),
      pageBuilder: (_, __, ___) => GameScreen(
        words: words,
        track: kTracks.first,
        store: widget.store,
        mode: GameMode.quickPlay,
        recordProgress: false, // custom sets don't touch the SRS
      ),
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: anim, child: child),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final locale = appState.locale;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: FutureBuilder<void>(
          future: _future,
          builder: (context, snap) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Wordmark(size: 22),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(Strings.t(locale, 'mySets').toUpperCase(),
                          style: QType.mono(
                              size: 14, color: QColors.coral, spacing: 3)),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close, color: QColors.muted),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Text(Strings.t(locale, 'mySetsSub'),
                      style: QType.sans(
                          size: 13.5, color: QColors.muted, height: 1.5)),
                  const SizedBox(height: 18),
                  _CoralButton(
                    label: Strings.t(locale, 'newSet'),
                    onTap: () => _openEditor(),
                  ),
                  const SizedBox(height: 22),
                  if (_setStore.sets.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: Text(Strings.t(locale, 'emptySets'),
                          style: QType.mono(
                              size: 11, color: QColors.dim, spacing: 1)),
                    )
                  else
                    for (final set in _setStore.sets)
                      _SetTile(
                        set: set,
                        locale: locale,
                        onPlay: () => _play(set),
                        onEdit: () => _openEditor(set),
                        onDelete: () async {
                          await _setStore.delete(set.id);
                          if (mounted) setState(() {});
                        },
                      ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SetTile extends StatelessWidget {
  final CustomSet set;
  final String locale;
  final VoidCallback onPlay, onEdit, onDelete;
  const _SetTile({
    required this.set,
    required this.locale,
    required this.onPlay,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: set.count > 0 ? onPlay : onEdit,
        child: Container(
          padding: const EdgeInsets.fromLTRB(15, 14, 8, 14),
          decoration: BoxDecoration(
            color: QColors.panel,
            border: Border.all(color: QColors.rule),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(set.name,
                        style: QType.serif(size: 17, color: QColors.cream)),
                    const SizedBox(height: 2),
                    Text(
                        Strings.t(locale, 'entriesCount')
                            .replaceFirst('{n}', '${set.count}'),
                        style: QType.mono(
                            size: 10, color: QColors.dim, spacing: 1)),
                  ]),
            ),
            IconButton(
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined,
                  size: 18, color: QColors.muted),
            ),
            IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline,
                  size: 18, color: QColors.dim),
            ),
            if (set.count > 0)
              const Icon(Icons.play_arrow, color: QColors.coral),
            const SizedBox(width: 4),
          ]),
        ),
      ),
    );
  }
}

class _CoralButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _CoralButton({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: QColors.coral,
          foregroundColor: const Color(0xFF160603),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        onPressed: onTap,
        icon: const Icon(Icons.add, size: 18, color: Color(0xFF160603)),
        label: Text(label.toUpperCase(),
            style: QType.mono(size: 12, color: const Color(0xFF160603), spacing: 2)),
      ),
    );
  }
}
