import ActivityKit
import AppIntents
import FacePassCompanionCore
import SwiftUI
import WidgetKit

@available(iOSApplicationExtension 17.0, *)
struct StandByUnlockLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StandByUnlockActivityAttributes.self) { context in
            StandByUnlockActivityCard(context: context)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.accentColor)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("FacePass", systemImage: "lock.shield")
                        .font(.headline)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(statusText(for: context))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    Button(intent: StandByUnlockIntent()) {
                        Label("Unlock Mac", systemImage: "lock.open")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } compactLeading: {
                Image(systemName: "lock.shield")
            } compactTrailing: {
                Text(compactStatusText(for: context))
            } minimal: {
                Image(systemName: "lock.open")
            }
        }
    }

    private func statusText(for context: ActivityViewContext<StandByUnlockActivityAttributes>) -> String {
        context.state.status.isEmpty ? "FacePass Ready" : context.state.status
    }

    private func compactStatusText(for context: ActivityViewContext<StandByUnlockActivityAttributes>) -> String {
        context.state.isRequestInFlight ? "..." : "Ready"
    }
}

@available(iOSApplicationExtension 17.0, *)
private struct StandByUnlockActivityCard: View {
    let context: ActivityViewContext<StandByUnlockActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("FacePass Ready")
                        .font(.headline)
                        .lineLimit(1)

                    Text(context.attributes.macDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
            }

            HStack(alignment: .center, spacing: 12) {
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer(minLength: 8)

                Button(intent: StandByUnlockIntent()) {
                    Label("Unlock Mac", systemImage: "lock.open")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private var statusText: String {
        context.state.status.isEmpty ? "FacePass Ready" : context.state.status
    }
}
