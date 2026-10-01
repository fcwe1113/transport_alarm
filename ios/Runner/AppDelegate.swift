import Flutter
import UIKit
import GoogleMaps
import Firebase
import UserNotifications

let appGroupId = "group.com.fcwe1113.busArrivalNotificationApp.66RCG95DR7"
var apnsTokenChannel: FlutterMethodChannel?

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupId)
    }

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                NSLog("DEBUG TEST: notification init")
                DispatchQueue.main.async { application.registerForRemoteNotifications() }
            }
        }

        if let container = AppGroup.containerURL {
            let testFile = container.appendingPathComponent("app_group_test.txt")
            let message = "written by main app at \(Date())"
            do {
                try message.write(to: testFile, atomically: true, encoding: .utf8)
                NSLog("APP GROUP TEST: wrote file to \(testFile.path)")
            } catch {
                NSLog("APP GROUP TEST: write failed: \(error)")
            }
        } else {
            NSLog("APP GROUP TEST: containerURL is nil - entitlement likely missing or misconfigged")
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

        let messenger = engineBridge.applicationRegistrar.messenger()

        apnsTokenChannel = FlutterMethodChannel(
            name: "com.fcwe1113.transport_alarm/apns_token",
            binaryMessenger: messenger
        )

        let mapsChannel = FlutterMethodChannel(
            name: "com.fcwe1113.transport_alarm/google_maps",
            binaryMessenger: messenger
        )
        mapsChannel.setMethodCallHandler { call, result in
            if call.method == "setApiKey",
               let args = call.arguments as? [String: Any],
               let apiKey = args["apiKey"] as? String {
                GMSServices.provideAPIKey(apiKey)
                result(true)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }

        let alarmKitChannel = FlutterMethodChannel(
            name: "com.fcwe1113.transport_alarm/alarmkit",
            binaryMessenger: messenger
        )
        alarmKitChannel.setMethodCallHandler { call, result in
            AlarmKitBridge.handle(call: call, result: result)
        }
    }

    override func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
//        NSLog("DEBUG_SWIFT_PUSH: Received push notification in foreground: %@", notification.request.content.userInfo)
        if #available(iOS 14.0, *) {
//            NSLog("DEBUG_SWIFT_PUSH: passing into dart")
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
        NSLog("APNS TOKEN: \(tokenString)")
        apnsTokenChannel?.invokeMethod("onTokenReceived", arguments: tokenString)

        super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    }

    // Log APNs registration errors
    override func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("APNS registration failed: \(error.localizedDescription)")

        super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
    }

}
