import Flutter
import AlarmKit
import Foundation

/// The alarmkit method channel, for AlarmKitService in Dart. Nothing calls it
/// yet; it's kept for a possible AlarmKit backup to the server pings.
enum AlarmKitBridge {
    static func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "requestAuthorization":
            requestAuthorization(result: result)
        case "armAlarm":
            armAlarm(call: call, result: result)
        case "cancelAlarm":
            cancelAlarm(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private static func requestAuthorization(result: @escaping FlutterResult) {
        Task {
            do {
                result(try await AlarmKitScheduler.requestAuthorization())
            } catch {
                result(FlutterError(code: "AUTHORIZATION_FAILED", message: error.localizedDescription, details: nil))
            }
        }
    }

    private static func armAlarm(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let alarmID = args["alarmId"] as? String, !alarmID.isEmpty,
              let secondsUntilFire = args["secondsUntilFire"] as? Double,
              let title = args["title"] as? String else {
            result(FlutterError(code: "BAD_ARGS", message: "Missing alarmId, secondsUntilFire, or title", details: nil))
            return
        }
        Task {
            do {
                try await AlarmKitScheduler.schedule(
                    alarmID: alarmKitID(for: alarmID),
                    secondsUntilFire: secondsUntilFire,
                    title: title
                )
                result(true)
            } catch {
                result(FlutterError(code: "SCHEDULE_FAILED", message: error.localizedDescription, details: nil))
            }
        }
    }

    private static func cancelAlarm(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let alarmID = args["alarmId"] as? String, !alarmID.isEmpty else {
            result(FlutterError(code: "BAD_ARGS", message: "Missing alarmId", details: nil))
            return
        }
        try? AlarmKitScheduler.cancel(alarmID: alarmKitID(for: alarmID))
        result(true)
    }

    /// AlarmKit needs a UUID; app alarm IDs are timestamps, so they map to a
    /// stable one. Arming and cancelling must agree, so both use this.
    private static func alarmKitID(for alarmID: String) -> UUID {
        UUID(uuidString: alarmID) ?? AlarmKitScheduler.stableID(for: alarmID)
    }
}
