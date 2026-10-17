import SwiftUI
import WidgetKit

struct BedEntry: TimelineEntry {
    let date: Date
    let level: Int?
    let isOn: Bool?
}

struct BedProvider: TimelineProvider {
    func placeholder(in context: Context) -> BedEntry {
        BedEntry(date: Date(), level: 30, isOn: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (BedEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BedEntry>) -> Void) {
        // Static: the watch app reloads timelines after each successful change.
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> BedEntry {
        BedEntry(date: Date(), level: SharedSettings.lastLevel, isOn: SharedSettings.lastIsOn)
    }
}

struct BedTempWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BedEntry

    private var levelText: String? { entry.level.map(TemperatureFormat.levelText(raw:)) }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "bed.double.fill")
                        .font(.system(size: 18, weight: .semibold))
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 12, weight: .semibold))
                }
                .widgetAccentable()
            }
        case .accessoryCorner:
            Image(systemName: "bed.double.fill")
                .font(.title3)
                .widgetAccentable()
                .widgetLabel { Text(levelText.map { "Bed \($0)" } ?? "Bed temp") }
        case .accessoryInline:
            Label(levelText.map { "Bed \($0)" } ?? "Bed", systemImage: "bed.double.fill")
        default:
            HStack(spacing: 8) {
                Image(systemName: "bed.double.fill")
                    .font(.title2)
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Eight Sleep")
                        .font(.headline)
                        .widgetAccentable()
                    if let level = entry.level {
                        Text("\(TemperatureFormat.levelText(raw: level))  \(TemperatureFormat.fahrenheitText(raw: level))")
                            .font(.body.monospacedDigit())
                        if entry.isOn == false {
                            Text("Off").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Tap to adjust").foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

@main
struct BedTempWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BedTemp", provider: BedProvider()) { entry in
            BedTempWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Bed Temp")
        .description("Open Eight Sleep Remote")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}
