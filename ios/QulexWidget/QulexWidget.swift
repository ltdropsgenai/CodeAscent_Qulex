//  QulexWidget.swift
//  Home-screen and lock-screen widget showing a word from the learner's own
//  due pile — the same word the daily notification surfaces.
//
//  The Dart side (lib/services/widget_service.dart) writes two keys into the
//  shared App Group container via home_widget:
//      "word"     the headword
//      "meaning"  its gloss in the learner's chosen language
//  home_widget stores them as plain keys in UserDefaults(suiteName:), so they
//  are read back below with the same names. Change one side and the widget
//  silently shows placeholder text, so keep these in step.

import WidgetKit
import SwiftUI

private let kAppGroup = "group.com.codeascent.qbit"
private let kWordKey = "word"
private let kMeaningKey = "meaning"

struct QulexEntry: TimelineEntry {
    let date: Date
    let word: String
    let meaning: String
}

struct Provider: TimelineProvider {
    // Shown while the widget gallery renders a preview — never real data.
    func placeholder(in context: Context) -> QulexEntry {
        QulexEntry(date: Date(), word: "Qulex", meaning: "Tap to learn a word")
    }

    func getSnapshot(in context: Context, completion: @escaping (QulexEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QulexEntry>) -> Void) {
        // The app pushes a new word whenever the due pile changes, so there is
        // nothing to schedule ahead. Refresh in an hour as a floor in case the
        // app has not been opened.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        completion(Timeline(entries: [readEntry()], policy: .after(next)))
    }

    private func readEntry() -> QulexEntry {
        let defaults = UserDefaults(suiteName: kAppGroup)
        let word = defaults?.string(forKey: kWordKey) ?? "Qulex"
        let meaning = defaults?.string(forKey: kMeaningKey) ?? "Tap to learn a word"
        return QulexEntry(date: Date(), word: word, meaning: meaning)
    }
}

// Qulex palette, kept in step with lib/theme.dart.
private extension Color {
    static let qCoral = Color(red: 1.0, green: 0.353, blue: 0.235) // #FF5A3C
    static let qCream = Color(red: 0.957, green: 0.945, blue: 0.918) // #F4F1EA
    static let qBg = Color(red: 0.027, green: 0.027, blue: 0.039) // #07070A
}

struct QulexWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: Provider.Entry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            // Lock screen: no colour, no background — the system tints it.
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.word).font(.headline).lineLimit(1)
                Text(entry.meaning).font(.caption2).lineLimit(2)
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Text("WORD OF THE MOMENT")
                    .font(.system(size: 9, weight: .medium))
                    .kerning(1.1)
                    .foregroundColor(.qCoral)
                Text(entry.word)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.qCream)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(entry.meaning)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.69))
                    .lineLimit(family == .systemSmall ? 3 : 2)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@main
struct QulexWidget: Widget {
    let kind = "QulexWidget" // must match iOSName in widget_service.dart

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            if #available(iOS 17.0, *) {
                QulexWidgetEntryView(entry: entry)
                    .containerBackground(Color.qBg, for: .widget)
            } else {
                QulexWidgetEntryView(entry: entry)
                    .padding(14)
                    .background(Color.qBg)
            }
        }
        .configurationDisplayName("Word of the moment")
        .description("A word from your own pile, waiting on your home screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}
