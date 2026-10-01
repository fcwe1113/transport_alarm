import Flutter
import AlarmKit

struct TransportAlarmBridge: AlarmMetadata {

    enum AlarmKitBridge {
        static func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
            switch call.method {
            case "armAlarm":
                self.armAlarm(call: call, result: result)
            case "cancelAlarm":
                self.cancelAlarm(call: call, result: result)
            default: //  should never happen
                result(FlutterMethodNotImplemented)
            }
        }

        private func armAlarm(call: FlutterMethodCall, result: @escaping FlutterResult) {
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
                    let state = try await AlarmManager.shared.requestAuthorization()
                    guard state == .authorized else {
                        result(FlutterError(code: "NOT_AUTHORIZED", message: "AlarmKit not authorized", details: nil))
                        return
                    }

                    typealias Config = AlarmManager.AlarmConfiguration<TransportAlarmMetadata>

                    let stopButton = AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle")
                    let alertPresentation = AlarmPresentation.alert(title: LocalizedStringResource(stringLiteral: title), stopButton: stopButton)
                    let attributes = AlarmAttributes<TransportAlarmMetadata>(presentation: alarmPresentation(alert: alertPresentation), tintColor: .blue)
                    let duration = Alarm.CountDownDuration(preAlert: TimeInterval(secondsUntilFire), postAlert: nil) // todo check
                    let configuration = Config(countdownDuration: duration, attributes: attributes)

                    _ = try await AlarmManager.shared.schedule(id: alarmId, configuration: configuration)
                    result(true)
                } catch {
                    result(FlutterError(code: "SCHEDULE_FAILED", message: error.localizedDescription, details: nil))
                }
            }
        }

        private func cancelAlarm(call: FlutterMethodCall, result: @escaping FlutterResult) {
            guard let args = call.arguments as? [String: Any],
                  let alarmIdString = args["alarmId"] as? String,
                  let alarmId = UUID(uuidString: alarmIdString) else {
                result(FlutterError(code: "BAD_ARGS", message: "Missing or invalid alarmId", details: nil))
                return
            }

            Task {
                do {
                    try await AlarmManager.shared.cancel(id: alarmId)
                    result(true)
                } catch {
                    result(FlutterError(ccode: "CANCEL_FAILED", message: error.localizedDescription, details: nil))
                }
            }
        }
    }
}