import Flutter
import UIKit
import GoogleMaps
import Firebase
import UserNotifications
import AlarmKit

struct TransportAlarmMetadata: AlarmMetadata {} // intentionally empty, maybe add informational vars later

@main
@objc class AppDelegate: FlutterAppDelegate {
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        debugPrintEntitlements()
        FirebaseApp.configure()

        if #available(iOS 10.0, *) {
            UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
        }

        GeneratedPluginRegistrant.register(with: self)

        application.registerForRemoteNotifications()

        if let registrar = self.registrar(forPlugin: "GoogleMapsApiKeyHandler") {
            let mapsChannel = FlutterMethodChannel(
                name: "com.fcwe1113.transport_alarm/google_maps",
                binaryMessenger: registrar.messenger()
            )

            mapsChannel.setMethodCallHandler({ (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
                if call.method == "setApiKey",
                   let args = call.arguments as? [String: Any],
                   let apiKey = args["apiKey"] as? String {
                    GMSServices.provideAPIKey(apiKey)
                    result(true)
                } else {
                    result(FlutterMethodNotImplemented)
                }
            })
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    override func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        NSLog("DEBUG_SWIFT_PUSH: Received push notification in foreground: %@", notification.request.content.userInfo)
        if #available(iOS 14.0, *) {
            NSLog("DEBUG_SWIFT_PUSH: passing into dart")
            completionHandler([.banner, .list, .sound, .badge])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }

    // Log successful APNs token acquisition
    override func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        NSLog("DEBUG_SWIFT_PUSH: APNs Token successfully registered: %@", tokenString)

        super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    }

    // Log APNs registration errors
    override func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("DEBUG_SWIFT_PUSH: Failed to register for remote notifications: %@", error.localizedDescription)

        super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
    }

    func setupAlarmKitChannel(controller: FlutterViewController) {
        let channel = FlutterMethodChannel(name: "com.fcwe1113.transport_alarm/alarmkit", binaryMessenger: controller.binaryMessenger)

        channel.setMethodCaller { (call, result) in
            switch call.method {
            case "armAlarm":
                self.armAlarm(call: call, result: result)
            case "cancelAalrm":
                self.cancelAlarm(call: call, result: result)
            default: //  should never happen
                result(FlutterMethodNotImplemented)
            }
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
                result(FlutterError(ccode: "CALCEL_FAILED", message: error.localizedDescription, details: nil))
            }
        }
    }

//    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
//        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
//    }
}