import AlarmKit
import SwiftUI
import WidgetKit

/// Supplies the countdown Live Activity UI required by AlarmKit.
struct TransportAlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<TransportAlarmMetadata>.self) { _ in
            Text("Transport alarm")
                .font(.headline)
                .padding()
        } dynamicIsland: { _ in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text("Transport alarm")
                }
            } compactLeading: {
                Image(systemName: "bus.fill")
            } compactTrailing: {
                Text("Alarm")
            } minimal: {
                Image(systemName: "bus.fill")
            }
        }
    }
}

@main
struct TransportAlarmWidgetBundle: WidgetBundle {
    var body: some Widget {
        TransportAlarmLiveActivity()
    }
}
