import Flutter
import AlarmKit
import Foundation

/// The alarmkit method channel, for AlarmKitService in Dart. Nothing calls it
/// yet; it's kept for a possible AlarmKit backup to the server pings. Before
/// iOS 26.1, which this AlarmKit code needs, every call fails with UNSUPPORTED.
enum AlarmKitBridge {
    static func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard #available(iOS 26.1, *) else {
            result(FlutterError(code: "UNSUPPORTED", message: "AlarmKit needs iOS 26.1 or later", details: nil))
            return
        }
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

    @available(iOS 26.1, *)
    private static func requestAuthorization(result: @escaping FlutterResult) {
        Task {
            do {
                result(try await AlarmKitScheduler.requestAuthorization())
            } catch {
                result(FlutterError(code: "AUTHORIZATION_FAILED", message: error.localizedDescription, details: nil))
            }
        }
    }

    @available(iOS 26.1, *)
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

    @available(iOS 26.1, *)
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
    @available(iOS 26.1, *)
    private static func alarmKitID(for alarmID: String) -> UUID {
        UUID(uuidString: alarmID) ?? AlarmKitScheduler.stableID(for: alarmID)
    }
}
