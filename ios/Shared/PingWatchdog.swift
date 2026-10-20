import Foundation
import UserNotifications

/// A local notification that tells the user an alarm's server pings have
/// stopped. Each successful reschedule moves it past the next ping, so it only
/// fires when that ping and the server's first fallback resend both fail to
/// arrive, for example after the push token changes. A dead token means no
/// push can reach the phone, so only the phone itself can say so.
enum PingWatchdog {
    /// Long enough after a ping for the server's first fallback resend.
    private static let grace: TimeInterval = 7 * 60

    private static func identifier(alarmID: String) -> String {
        "ping_watchdog_\(alarmID)"
    }

    /// Fires the watchdog [grace] after [nextPingAt], replacing any earlier one.
    static func arm(alarmID: String, nextPingAt: Date) async {
        let center = UNUserNotificationCenter.current()
        let id = identifier(alarmID: alarmID)
        center.removeDeliveredNotifications(withIdentifiers: [id])
        let content = UNMutableNotificationContent()
        content.title = NativeLocalization.text("native.watchdog.title")
        content.body = NativeLocalization.text("native.watchdog.body")
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let interval = max(1, nextPingAt.addingTimeInterval(grace).timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        } catch {
            NSLog("Ping watchdog could not be scheduled: %@", error.localizedDescription)
        }
    }

    /// Removes the watchdog once the alarm needs no more pings.
    static func disarm(alarmID: String) {
        let center = UNUserNotificationCenter.current()
        let id = identifier(alarmID: alarmID)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
}
