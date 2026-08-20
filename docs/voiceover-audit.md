# VoiceOver audit — the part only a device can do

Build 36 took accessibility from 5 references in the whole app to 97, and
`adaptive_frames_test.dart` / `game_a11y_test.dart` assert the semantics tree
and fail on layout overflow at 1×, 1.5× and 2× text. None of that is the same
as a screen reader on a phone, which is why the capability board still scores
this row **partial** rather than shipped. It moves to shipped when someone has
actually run the pass below.

Budget **25 minutes**. You need an iPhone with the TestFlight build; a
simulator will not do, because VoiceOver's gestures and its focus order differ
enough there to give false confidence.

## Setup

1. Settings → Accessibility → **Accessibility Shortcut** → VoiceOver. Now a
   triple-click of the side button toggles it, which you will want.
2. Settings → Accessibility → Display & Text Size → **Larger Text** → drag to
   the largest *non-accessibility* size for the second half of this pass.
3. Learn two gestures and you can do the whole audit: **swipe right** moves to
   the next element, **double-tap** activates the focused one.

## What "passing" means

For every control: it is **reachable** by swiping, it **says what it is**, and
for anything stateful it **says what state it is in**. A control that VoiceOver
reads as just "button" has failed even if it works.

---

## 1. Home — 4 min

| Focus this | Should say | Fails if |
|---|---|---|
| The three stat cells | "Vocab rank, 800" — label *and* value together | it reads "800" and "VOCAB RANK" as two separate stops |
| Daily Challenge | "Daily Challenge, button" + the subtitle as a hint | it reads the icon, or splits into three fragments |
| The gear icon | "Settings, button" | it says only "button" |
| The account icon | "Account, button" | as above |
| A track row | the track name, then its description as a hint | |
| Start quick play | "Start quick play, button" — **sentence case** | it spells out S-T-A-R-T (all-caps leaked into the label) |

The stat cells and the daily banner are the two that were genuinely broken
before, so if anything regresses it will be those.

## 2. A round — 8 min, the important one

Start a Quick Play round.

1. **Swipe to the progress ticks.** Should say "Question, 1 / 10". This strip
   is pure colour on screen — if it is silent, a screen-reader user has no idea
   how far through they are.
2. **Swipe to the timer.** Should say "Time left" and a number of seconds. It
   should **not** re-announce itself constantly — if it interrupts you every
   second, the live-region setting is wrong and the round is unusable.
3. **Swipe to score and streak.** "Score, 40". Not a bare "40".
4. **Answer a question by double-tapping an option.** Then swipe back over the
   three options. Exactly one must now read **"…, Correct"** and, if you got it
   wrong, one must read **"…, Not correct"**.
   *This is the single most important check in the audit.* Right and wrong are
   drawn in coral against amber — the worst pair in the palette for a red-green
   deficiency and invisible to a screen reader. If the verdict is not in the
   words, the game is unplayable without colour vision.
5. **After answering**, the reveal panel should announce itself without you
   going to find it. If it stays silent until you swipe to it, the live region
   is not firing.
6. **The back arrow** should say "Quit round".
7. Play three or four questions end to end with your eyes shut. That is the
   real test, and it is the one that finds things a checklist does not.

## 3. Settings — 5 min

1. **Swipe through section headings.** "LEARNING", "PREFERENCES" and the rest
   should be announced as *headings*, so the rotor can jump between them. Turn
   the rotor to Headings and check you can.
2. **The New words per day stepper**: the number reads "New words per day, 20",
   and the two buttons read "Increase New words per day" / "Decrease…". Not
   two anonymous buttons around a digit.
3. **Review intensity**: the selected cell must say **"selected"**. Selection
   here is signalled by colour alone, so without this you cannot tell which is
   active.
4. **Every toggle** — Voice, Daily reminders, Top up on Wi-Fi — must say
   "on"/"off" and offer the toggle gesture.
5. **Offline voice**: start a download and check the progress announces as a
   percentage rather than sitting there mute.

## 4. Large text — 5 min

Turn VoiceOver **off** and Larger Text up to maximum non-accessibility size.

- **Settings**: rows should stack — control *below* its title, not squeezed
  beside it. Review intensity should become a vertical list with a coral bar on
  the left. Nothing clipped, nothing cut off at the right edge.
- **A round**: all three answers readable, and the **Next** button still
  reachable (scroll if you must — it must exist).
- Then push into the **accessibility** sizes. Qulex clamps at 2×, so past a
  point text should stop growing. That is deliberate; note it if it looks
  wrong, but it is not a bug.

## 5. Reduce Motion — 2 min

Settings → Accessibility → Motion → **Reduce Motion** on. Cold-start the app.

- The title sequence and the "Let's learn" beat should be calm and short — no
  flashing at all.
- The drifting word field should not appear.
- The photographic backdrop should stop its slow Ken Burns drift.

---

## Recording the result

Note anything that fails as *screen → control → what it said → what it should
have said*. That maps one-to-one onto a fix.

If the whole pass is clean, the accessibility row on the capability board moves
from **partial** to **shipped**, and it will be the first time that claim rests
on evidence rather than on a test harness asserting its own assumptions.
