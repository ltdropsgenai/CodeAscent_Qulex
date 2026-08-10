import '../models/word.dart';

/// An onboarding "track" — same engine, different word pool + copy.
/// Keep the filters here so product can tune segmentation in one place.
class Track {
  final String id;
  final String icon; // emoji for the prototype UI
  final String title;
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

const List<String> _testTags = ['SAT', 'GRE', 'IELTS'];

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
    id: 'test',
    icon: '🎓',
    title: 'Ace a test',
    subtitle: 'SAT / GRE / IELTS words',
    filter: (w) => w.tags.any(_testTags.contains),
  ),
];
