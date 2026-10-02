import AlarmKit
import ActivityKit
import SwiftUI
import WidgetKit

/// Supplies the countdown Live Activity UI required by AlarmKit.
struct TransportAlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<TransportAlarmMetadata>.self) { context in
            activityContent(context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    activityContent(context)
                }
            } compactLeading: {
                Image(systemName: "bus.fill")
            } compactTrailing: {
                Text(NativeLocalization.text("live_activity.bus"))
            } minimal: {
                Image(systemName: "bus.fill")
            }
        }
    }
}

/// Renders the system-provided AlarmKit state, including a ticking pre-alert countdown.
@ViewBuilder
private func activityContent(
    _ context: ActivityViewContext<AlarmAttributes<TransportAlarmMetadata>>
) -> some View {
    switch context.state.mode {
    case .countdown(let countdown):
        VStack(spacing: 4) {
            Text(NativeLocalization.text("live_activity.title"))
                .font(.headline)
            Text(timerInterval: countdown.startDate...countdown.fireDate, countsDown: true)
                .monospacedDigit()
        }
        .padding()
    case .paused:
        Text(NativeLocalization.text("live_activity.paused"))
            .font(.headline)
            .padding()
    case .alert:
        Text(NativeLocalization.text("live_activity.title"))
            .font(.headline)
            .padding()
    }
}

@main
struct TransportAlarmWidgetBundle: WidgetBundle {
    var body: some Widget {
        TransportAlarmLiveActivity()
    }
}
