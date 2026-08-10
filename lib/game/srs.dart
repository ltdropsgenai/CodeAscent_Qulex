/// Leitner-style spaced repetition scheduling.
///
/// A correct answer promotes a word up a box (longer interval before it's due
/// again); a miss sends it back to box 0 (due almost immediately). Intervals
/// are deliberately short for a fast, game-like prototype — lengthen them for a
/// real study app.
class Srs {
  static const int maxBox = 5;

  /// Minutes until a word in each box is due again.
  /// box: 0 -> ~now, 1 -> 10m, 2 -> 1h, 3 -> 1 day, 4 -> 3 days, 5 -> 7 days
  static const List<int> intervalMinutes = [1, 10, 60, 1440, 4320, 10080];

  static int nextBox(int box, bool correct) {
    if (!correct) return 0;
    final n = box + 1;
    return n > maxBox ? maxBox : n;
  }

  /// [scale] stretches or compresses the interval for the user's chosen review
  /// intensity: <1 = more frequent (intense), >1 = more relaxed.
  static int dueFrom(int nowMillis, int box, {double scale = 1.0}) {
    final b = box < 0 ? 0 : (box > maxBox ? maxBox : box);
    final mins = (intervalMinutes[b] * scale).round();
    return nowMillis + mins * 60000;
  }
}
