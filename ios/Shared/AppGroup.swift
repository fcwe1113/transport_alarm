import Foundation

/// The App Group the app, the notification extension and the widget share:
/// alarms.json, the GTFS databases and their shared preferences live in it.
enum AppGroup {
    static let identifier = "group.com.fcwe1113.busArrivalNotificationApp.66RCG95DR7"

    /// Nil if the target lacks the App Group entitlement.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var defaults: UserDefaults? { UserDefaults(suiteName: identifier) }
}

/// The hints that a ring's Acknowledge action works without opening the app:
/// a line on the ring until the user first uses it, and a tip in the app,
/// once, after acknowledging by opening the app.
enum AcknowledgeTips {
    private static let usedActionKey = "acknowledged_from_notification"
    private static let tipPendingKey = "acknowledge_tip_pending"
    private static let tipShownKey = "acknowledge_tip_shown"

    static var usedAction: Bool { AppGroup.defaults?.bool(forKey: usedActionKey) ?? false }

    static func markUsedAction() {
        AppGroup.defaults?.set(true, forKey: usedActionKey)
    }

    /// The ring was acknowledged by tapping it, which opens the app.
    static func markAcknowledgedByOpening() {
        guard let defaults = AppGroup.defaults,
              !usedAction, !defaults.bool(forKey: tipShownKey) else { return }
        defaults.set(true, forKey: tipPendingKey)
    }

    /// Whether the app should show the tip now; true only once.
    static func takeTip() -> Bool {
        guard let defaults = AppGroup.defaults, defaults.bool(forKey: tipPendingKey) else { return false }
        defaults.removeObject(forKey: tipPendingKey)
        if usedAction || defaults.bool(forKey: tipShownKey) { return false }
        defaults.set(true, forKey: tipShownKey)
        return true
    }
}
