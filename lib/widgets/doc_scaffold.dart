import 'package:flutter/material.dart';

import '../layout.dart';
import '../theme.dart';
import 'wordmark.dart';

/// Shared scaffold for text pages (About / Privacy / Security). Transparent
/// over the global backdrop, with a wordmark header and a close button.
class DocScaffold extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const DocScaffold({super.key, required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        // Prose gets no better past a comfortable measure, so on a wide
        // display the page stays a reading column and centres instead of
        // stretching a paragraph to 1,100pt. See QLayout.readingWidth.
        child: ReadingColumn(
          child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Wordmark(size: 22),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(title.toUpperCase(),
                      style: QType.mono(
                          size: 14, color: QColors.coral, spacing: 3)),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  // An icon-only control is invisible to a screen reader
                  // without this; it reads as "button" and nothing else.
                  tooltip: 'Close',
                  icon: const Icon(Icons.close,
                      color: QColors.muted, semanticLabel: 'Close'),
                ),
              ]),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
          ),
        ),
      ),
    );
  }
}

/// A section heading inside a doc page.
Widget docHeading(String text) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(text,
          style: QType.serif(size: 19, color: QColors.cream, height: 1.2)),
    );

/// A body paragraph inside a doc page.
Widget docBody(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(text,
          style: QType.sans(size: 13.5, color: QColors.muted, height: 1.55)),
    );

/// A small muted caption (dates, versions).
Widget docNote(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text,
          style: QType.mono(size: 10.5, color: QColors.dim, spacing: 0.5)),
    );
