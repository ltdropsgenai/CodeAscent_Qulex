import '../models/word.dart';

/// An onboarding "track" — same engine, different word pool + copy.
/// Keep the filters here so product can tune segmentation in one place.
///
/// Display copy lives in the localization table under `track<Id>` and
/// `track<Id>Sub`, so a track's title is never hard-coded here.
class Track {
  final String id;
  final String icon; // emoji for the prototype UI
  final String title; // English fallback; UI reads the localized key
  final String subtitle;
  final bool Function(Word) filter;

  const Track({
    required this.id,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.filter,
  });
}

/// The exam tracks are honest about what they are.
///
/// There is no official word list for the SAT or the GRE. College Board
/// dropped isolated vocabulary in the 2016 redesign — the digital SAT tests
/// words in context — and ETS has never published one either. Every list sold
/// as "the SAT words" is a prep vendor's estimate. Our tags are the same kind
/// of estimate, so the copy says "style" rather than claiming an authority
/// that does not exist.
///
/// IELTS is the one that is properly sourced. The academic track matches the
/// Academic Word List (Coxhead 2000, TESOL Quarterly — 570 word families, the
/// recognised basis for academic English teaching), tagged `AWL` in the
/// catalogue. Note we do not redistribute the list: we use it to select from
/// words we already had, which is why the tag rather than the list is what
/// ships.
///
/// Coverage is partial and knowingly so. 322 of the 589 families have a
/// representative in the catalogue; the other 267 are absent entirely, and 64
/// of those sit in sublists 1-2, the most frequent academic vocabulary in
/// English. See _to_delete/missing_awl.md for the backlog.
final List<Track> kTracks = [
  Track(
    id: 'fun',
    icon: '🎯',
    title: 'Just for fun',
    subtitle: 'A mix of everything',
    filter: (_) => true,
  ),
  Track(
    id: 'esl',
    icon: '🌍',
    title: 'Level up my English',
    subtitle: 'Everyday + common words',
    filter: (w) => w.tags.contains('everyday') || w.difficulty != 'hard',
  ),
  Track(
    id: 'sat',
    icon: '📐',
    title: 'SAT-style words',
    subtitle: 'High-frequency exam vocabulary',
    filter: (w) => w.tags.contains('SAT'),
  ),
  Track(
    id: 'gre',
    icon: '🎓',
    title: 'GRE-style words',
    subtitle: 'Advanced academic vocabulary',
    filter: (w) => w.tags.contains('GRE'),
  ),
  Track(
    id: 'ielts',
    icon: '📘',
    title: 'IELTS & academic',
    subtitle: 'Academic English vocabulary',
    filter: (w) => w.tags.contains('AWL') || w.tags.contains('IELTS'),
  ),
];

/// Builds the pool of words a track can deal from.
///
/// Tag-backed tracks are thin: the exam tags cover 484 of 16,808 words, and
/// IELTS alone only 41. Dealing the same 41 words forever is worse than
/// slightly widening the net, so a short pool is topped up with words of
/// comparable difficulty and frequency to the ones the track did match. The
/// track's own words always come first, and a track that is already big
/// enough is returned untouched — so 'fun' and 'esl' are unaffected.
///
/// This is why the copy says "exam-style": past the first few dozen words, a
/// thin track genuinely is style-matched rather than tag-matched, and the
/// wording should not pretend otherwise.
List<Word> poolForTrack(Track track, List<Word> all, {int target = 200}) {
  final seed = all.where(track.filter).toList();
  if (seed.length >= target || seed.isEmpty) return seed;

  final seedIds = seed.map((w) => w.id).toSet();
  final seedDifficulties = seed.map((w) => w.difficulty).toSet();
  final ranks = seed.map((w) => w.freqRank).toList()..sort();
  final median = ranks[ranks.length ~/ 2];

  final extras = all
      .where((w) =>
          !seedIds.contains(w.id) && seedDifficulties.contains(w.difficulty))
      .toList()
    ..sort((a, b) =>
        (a.freqRank - median).abs().compareTo((b.freqRank - median).abs()));

  return [...seed, ...extras.take(target - seed.length)];
}
