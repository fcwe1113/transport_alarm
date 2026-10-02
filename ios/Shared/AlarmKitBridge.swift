import Flutter
import AlarmKit
import Foundation

enum AlarmKitBridge {
    static func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "requestAuthorization":
            requestAuthorization(result: result)
        case "armAlarm":
            self.armAlarm(call: call, result: result)
        case "cancelAlarm":
            self.cancelAlarm(call: call, result: result)
        default: //  should never happen
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
              let alarmIdString = args["alarmId"] as? String,
              let secondsUntilFire = args["secondsUntilFire"] as? Double,
              let title = args["title"] as? String else {
            result(FlutterError(code: "BAD_ARGS", message: "Missing alarmId, secondsUntilFire, or title", details: nil))
            return
        }

        guard let alarmId = UUID(uuidString: alarmIdString) else {
            result(FlutterError(code: "BAD_ARGS", message: "alarmId is not a valid UUID", details: nil))
            return
        }

        Task {
            do {
                try await AlarmKitScheduler.schedule(
                    alarmID: alarmId,
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
              let alarmIdString = args["alarmId"] as? String,
              !alarmIdString.isEmpty else {
            result(FlutterError(code: "BAD_ARGS", message: "Missing alarmId", details: nil))
            return
        }

        Task {
            for alarmID in alarmKitIDs(for: alarmIdString) {
                try? AlarmKitScheduler.cancel(alarmID: alarmID)
            }
            result(true)
        }
    }

    private static func alarmKitIDs(for alarmId: String) -> [UUID] {
        if let container = AppGroup.containerURL,
           let data = try? Data(contentsOf: container.appendingPathComponent("alarms.json")),
           let alarms = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let alarm = alarms.first(where: { ($0["id"] as? String) == alarmId }) {
            let states = (alarm["iosThresholdStates"] as? [[String: Any]])
                ?? (alarm["thresholdStates"] as? [[String: Any]])
                ?? []
            let occurrenceKey = alarm["iosOccurrenceKey"] as? String ?? "current"
            let sorted = states.sorted {
                (($0["minutesBeforeArrival"] as? NSNumber)?.intValue ?? 0) >
                    (($1["minutesBeforeArrival"] as? NSNumber)?.intValue ?? 0)
            }
            let ids = sorted.enumerated().compactMap { index, state -> UUID? in
                guard let minutes = (state["minutesBeforeArrival"] as? NSNumber)?.intValue else { return nil }
                return AlarmKitScheduler.stableID(for: "\(alarmId):\(occurrenceKey):threshold:\(minutes):\(index)")
            }
            if !ids.isEmpty { return ids }
        }

        return [UUID(uuidString: alarmId) ?? AlarmKitScheduler.stableID(for: alarmId)]
    }
}
