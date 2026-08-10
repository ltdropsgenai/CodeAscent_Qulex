import 'package:flutter/material.dart';

import '../data/custom_set_store.dart';
import '../l10n/strings.dart';
import '../models/custom_set.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/wordmark.dart';

/// Create or edit a custom set: name it, paste-import term/meaning lines, or add
/// entries by hand.
class SetEditorScreen extends StatefulWidget {
  final CustomSet? existing;
  final CustomSetStore setStore;
  const SetEditorScreen({super.key, this.existing, required this.setStore});

  @override
  State<SetEditorScreen> createState() => _SetEditorScreenState();
}

class _SetEditorScreenState extends State<SetEditorScreen> {
  late final TextEditingController _name;
  final TextEditingController _paste = TextEditingController();
  final TextEditingController _term = TextEditingController();
  final TextEditingController _meaning = TextEditingController();
  late final List<CustomEntry> _entries;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _entries = List<CustomEntry>.from(widget.existing?.entries ?? const []);
  }

  @override
  void dispose() {
    _name.dispose();
    _paste.dispose();
    _term.dispose();
    _meaning.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: QType.mono(size: 12, color: QColors.cream)),
      backgroundColor: const Color(0xFF14141A),
      duration: const Duration(seconds: 2),
    ));
  }

  void _import(String locale) {
    final parsed = parseImport(_paste.text);
    if (parsed.isEmpty) {
      _snack(Strings.t(locale, 'importNone'));
      return;
    }
    setState(() {
      _entries.addAll(parsed);
      _paste.clear();
    });
    _snack(Strings.t(locale, 'importedN').replaceFirst('{n}', '${parsed.length}'));
  }

  void _addManual() {
    final t = _term.text.trim(), m = _meaning.text.trim();
    if (t.isEmpty || m.isEmpty) return;
    setState(() {
      _entries.add(CustomEntry(t, m));
      _term.clear();
      _meaning.clear();
    });
  }

  Future<void> _save(String locale) async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _snack(Strings.t(locale, 'needName'));
      return;
    }
    if (_entries.isEmpty) {
      _snack(Strings.t(locale, 'needEntries'));
      return;
    }
    final set = widget.existing ??
        CustomSet(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            name: name,
            entries: []);
    set.name = name;
    set.entries = _entries;
    await widget.setStore.upsert(set);
    if (mounted) Navigator.of(context).pop(true);
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
                  child: Text(
                      Strings.t(locale,
                              widget.existing == null ? 'newSet' : 'editSet')
                          .toUpperCase(),
                      style:
                          QType.mono(size: 14, color: QColors.coral, spacing: 3)),
                ),
                TextButton(
                  onPressed: () => _save(locale),
                  child: Text(Strings.t(locale, 'save').toUpperCase(),
                      style:
                          QType.mono(size: 12, color: QColors.coral, spacing: 1.5)),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close, color: QColors.muted),
                ),
              ]),
              const SizedBox(height: 12),
              _field(_name, Strings.t(locale, 'setNamePlaceholder'), false),
              const SizedBox(height: 20),
              Text(Strings.t(locale, 'pasteImport').toUpperCase(),
                  style: QType.mono(size: 10, color: QColors.dim, spacing: 2)),
              const SizedBox(height: 8),
              _field(_paste, Strings.t(locale, 'pasteHint'), true),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: QColors.rule),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6)),
                  ),
                  onPressed: () => _import(locale),
                  child: Text(Strings.t(locale, 'importBtn').toUpperCase(),
                      style: QType.mono(
                          size: 10.5, color: QColors.coral, spacing: 1)),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                  '${Strings.t(locale, 'entries').toUpperCase()} · ${_entries.length}',
                  style: QType.mono(size: 10, color: QColors.dim, spacing: 2)),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: _field(_term, Strings.t(locale, 'term'), false)),
                const SizedBox(width: 8),
                Expanded(
                    child: _field(_meaning, Strings.t(locale, 'meaning'), false)),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: _addManual,
                  icon: const Icon(Icons.add_circle_outline,
                      color: QColors.coral),
                ),
              ]),
              const SizedBox(height: 12),
              for (var i = 0; i < _entries.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Expanded(
                      child: RichText(
                        text: TextSpan(children: [
                          TextSpan(
                              text: _entries[i].term,
                              style: QType.serif(
                                  size: 15, color: QColors.cream)),
                          TextSpan(
                              text: '  —  ${_entries[i].meaning}',
                              style: QType.sans(size: 13, color: QColors.muted)),
                        ]),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => setState(() => _entries.removeAt(i)),
                      child: const Icon(Icons.close,
                          size: 16, color: QColors.dim),
                    ),
                  ]),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint, bool multiline) {
    return Container(
      decoration: BoxDecoration(
        color: QColors.panel,
        border: Border.all(color: QColors.rule),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: TextField(
        controller: c,
        maxLines: multiline ? 5 : 1,
        style: QType.sans(size: 14, color: QColors.cream),
        cursorColor: QColors.coral,
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: hint,
          hintStyle: QType.sans(size: 14, color: QColors.dim),
        ),
      ),
    );
  }
}
