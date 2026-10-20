import Foundation

/// The App Group the app, the notification extension and the widget share:
/// alarms.json, the GTFS databases and their shared preferences live in it.
enum AppGroup {
    static let identifier = "group.com.fcwe1113.busArrivalNotificationApp.66RCG95DR7"

    /// Nil if the target lacks the App Group entitlement.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
