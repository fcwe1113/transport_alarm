import Flutter
import UIKit
import GoogleMaps
import UserNotifications

/// Registers the ring notification's Acknowledge action, the push token,
/// and the method channels the Dart side uses for App Group storage, the
/// push token, the ping watchdog, Google Maps and AlarmKit. Ring
/// acknowledgements are handled here natively, not in Dart.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
    private static let ringCategory = "transport_alarm_ring"
    private static let acknowledgeAction = "transport_alarm_acknowledge"

    private var apnsTokenChannel: FlutterMethodChannel?
    private var apnsDeviceToken: String?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let acknowledge = UNNotificationAction(
            identifier: Self.acknowledgeAction,
            title: NativeLocalization.text("native.acknowledge"),
            options: [.foreground]
        )
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.ringCategory, actions: [acknowledge], intentIdentifiers: [], options: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            // Registering for a push token doesn't depend on alert permission.
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
        let messenger = engineBridge.applicationRegistrar.messenger()
        setUpAppGroupChannel(messenger)
        setUpTokenChannel(messenger)
        setUpWatchdogChannel(messenger)
        setUpMapsChannel(messenger)
        FlutterMethodChannel(name: "com.fcwe1113.transport_alarm/alarmkit", binaryMessenger: messenger)
            .setMethodCallHandler { call, result in AlarmKitBridge.handle(call: call, result: result) }
    }

    // MARK: Method channels

    /// The App Group container's path, and the app language for the
    /// extensions' notices.
    private func setUpAppGroupChannel(_ messenger: FlutterBinaryMessenger) {
        FlutterMethodChannel(name: "com.fcwe1113.transport_alarm/app_group", binaryMessenger: messenger)
            .setMethodCallHandler { call, result in
                switch call.method {
                case "containerPath":
                    result(AppGroup.containerURL?.path)
                case "setAppLanguageCode":
                    guard let languageCode = (call.arguments as? [String: Any])?["languageCode"] as? String else {
                        result(FlutterMethodNotImplemented)
                        return
                    }
                    // Read by NativeLocalization in every target.
                    UserDefaults(suiteName: AppGroup.identifier)?.set(languageCode, forKey: "app_language_code")
                    result(true)
                default:
                    result(FlutterMethodNotImplemented)
                }
            }
    }

    /// The current push token on request; new tokens are sent as they arrive.
    private func setUpTokenChannel(_ messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "com.fcwe1113.transport_alarm/apns_token", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            if call.method == "getToken" {
                result(self?.apnsDeviceToken)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }
        apnsTokenChannel = channel
    }

    /// Arms and disarms an alarm's ping watchdog notification.
    private func setUpWatchdogChannel(_ messenger: FlutterBinaryMessenger) {
        FlutterMethodChannel(name: "com.fcwe1113.transport_alarm/ping_watchdog", binaryMessenger: messenger)
            .setMethodCallHandler { call, result in
                let args = call.arguments as? [String: Any]
                guard let alarmID = args?["alarmId"] as? String else {
                    result(FlutterMethodNotImplemented)
                    return
                }
                switch call.method {
                case "arm":
                    guard let millis = (args?["nextPingAt"] as? NSNumber)?.doubleValue else {
                        result(FlutterMethodNotImplemented)
                        return
                    }
                    Task { @MainActor in
                        await PingWatchdog.arm(alarmID: alarmID, nextPingAt: Date(timeIntervalSince1970: millis / 1000))
                        result(true)
                    }
                case "disarm":
                    PingWatchdog.disarm(alarmID: alarmID)
                    result(true)
                default:
                    result(FlutterMethodNotImplemented)
                }
            }
    }

    /// Hands Google Maps its key, which Dart reads from the bundled secrets.
    private func setUpMapsChannel(_ messenger: FlutterBinaryMessenger) {
        FlutterMethodChannel(name: "com.fcwe1113.transport_alarm/google_maps", binaryMessenger: messenger)
            .setMethodCallHandler { call, result in
                guard call.method == "setApiKey",
                      let apiKey = (call.arguments as? [String: Any])?["apiKey"] as? String else {
                    result(FlutterMethodNotImplemented)
                    return
                }
                GMSServices.provideAPIKey(apiKey)
                result(true)
            }
    }

    // MARK: Notifications

    /// Shows notices while the app is open too.
    override func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    /// Acknowledges a ringing threshold when its ring is tapped or its
    /// Acknowledge action is chosen; anything else goes to the plugins.
    override func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let isAlarmRing = response.notification.request.content.categoryIdentifier == Self.ringCategory
        let isAcknowledgement = response.actionIdentifier == Self.acknowledgeAction
        let isNotificationTap = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        guard isAlarmRing && (isAcknowledgement || isNotificationTap) else {
            super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
            return
        }

        let info = response.notification.request.content.userInfo
        let data = info["data"] as? [String: Any]
        let pingID = [info["ping_id"], data?["ping_id"]].compactMap { candidate -> String? in
            if let string = candidate as? String { return string }
            if let number = candidate as? NSNumber { return number.stringValue }
            return nil
        }.first
        guard let pingID else {
            completionHandler()
            return
        }
        Task {
            await PingAcknowledgementHandler.acknowledge(pingID: pingID)
            completionHandler()
        }
    }

    // MARK: Push token

    override func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        apnsDeviceToken = tokenString
        apnsTokenChannel?.invokeMethod("onTokenReceived", arguments: tokenString)
        super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    }

    override func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("APNs registration failed: \(error.localizedDescription)")
        super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
    }
}
