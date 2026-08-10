# Qbit — App Base (v0.1)

A timed vocabulary-quiz game. This is the **MVP base** from the build spec: the
core loop, onboarding tracks, a progression-ready game controller, and the seed
dataset wired in. Built with Flutter (one codebase → iOS + Android + web).

## Run it

You need the Flutter SDK on your machine (this couldn't be built in the cloud
sandbox — Flutter's toolchain isn't reachable there). On your PC:

```bash
# 1. Install Flutter — https://docs.flutter.dev/get-started/install
#    Then confirm the toolchain is healthy:
flutter doctor

# 2. From this folder:
flutter pub get

# 3. Run on a device/emulator, or in Chrome to see it instantly:
flutter run                 # pick a device
flutter run -d chrome       # fastest way to preview
```

If `flutter create .` prompts you to regenerate platform folders, that's fine —
this zip ships `lib/`, `assets/`, and `pubspec.yaml`; running
`flutter create .` once inside the folder adds the `android/`, `ios/`, and
`web/` runners without touching your code.

## What's here

```
lib/
  main.dart                  app entry + MaterialApp/theme
  theme.dart                 color palette + ThemeData
  models/word.dart           Word + WordExample (matches dataset schema)
  data/word_repository.dart  loads assets/words.json (swap for API later)
  game/track.dart            onboarding tracks (fun / ESL / test) + filters
  game/game_controller.dart  match state: timer, scoring, streak, reveal, rank
  screens/home_screen.dart   track picker
  screens/game_screen.dart   the game loop + reveal + result card
assets/words.json            70-word seed dataset
```

## The core loop (implemented)

Prompt → 8s countdown → tap A/B/C → reveal (meaning + example) → score/streak →
next. After 10 rounds: an estimated **Vocab Rank** card. Same flow as the web
prototype.

## What's intentionally NOT here yet (next steps)

- **Persistence / spaced repetition** — `user_word_state` (Leitner boxes) and a
  real Vocab-Rank estimate. Add a local DB (Isar/Drift) or Supabase.
- **Daily Challenge & streaks across sessions** — needs storage + date logic.
- **Monetization** — wire RevenueCat for the free / Pro / lifetime / hardship
  ladder from the spec.
- **Backend** — replace `WordRepository`'s bundled JSON with a Supabase call so
  content updates without app releases.
- **Real content pipeline** — scale the dataset from 70 → 1,500–2,500 reviewed
  words via the LLM-draft + human-review flow.

## Notes

- Zero third-party runtime dependencies in the base (just Flutter + Material 3),
  so `flutter pub get` is fast and nothing can break on version drift.
- State uses a plain `ChangeNotifier`; swap for Riverpod/Bloc if you prefer.
- Example sentences are `source: "generated"` for the MVP — replace with cleared
  real-source quotes where rights allow.
