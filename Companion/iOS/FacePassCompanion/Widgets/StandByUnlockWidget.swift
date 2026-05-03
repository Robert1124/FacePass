import AppIntents
import SwiftUI
import WidgetKit

@available(iOSApplicationExtension 17.0, *)
struct StandByUnlockWidget: Widget {
    private let kind = "StandByUnlockWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StandByUnlockTimelineProvider()) { entry in
            StandByUnlockWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("FacePass Unlock")
        .description("Send a signed local FacePass unlock request to the paired desktop helper.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@available(iOSApplicationExtension 17.0, *)
private struct StandByUnlockTimelineEntry: TimelineEntry {
    let date: Date
}

@available(iOSApplicationExtension 17.0, *)
private struct StandByUnlockTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> StandByUnlockTimelineEntry {
        StandByUnlockTimelineEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (StandByUnlockTimelineEntry) -> Void) {
        completion(StandByUnlockTimelineEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StandByUnlockTimelineEntry>) -> Void) {
        let entry = StandByUnlockTimelineEntry(date: Date())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

@available(iOSApplicationExtension 17.0, *)
private struct StandByUnlockWidgetView: View {
    let entry: StandByUnlockTimelineEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .systemSmall {
                smallWidget
            } else {
                mediumWidget
            }
        }
    }

    private var smallWidget: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                widgetIcon()
                    .frame(width: 30, height: 30)

                Text("FacePass")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            unlockButton(size: 68, iconSize: 30)

            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var mediumWidget: some View {
        HStack(spacing: 16) {
            widgetIcon()
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 4) {
                Text("FacePass")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("Ready for paired Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)

            unlockButton(size: 60, iconSize: 26)
        }
        .padding()
    }

    private func widgetIcon() -> some View {
        Image("FacePassWidgetGlyph")
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }

    private func unlockButton(size: CGFloat, iconSize: CGFloat) -> some View {
        Button(intent: StandByUnlockIntent()) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: max(5, size * 0.085))

                Image(systemName: "lock.open.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Unlock Mac")
    }
}
