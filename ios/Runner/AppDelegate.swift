import Flutter
import UIKit
import GoogleMaps
import Firebase
import UserNotifications

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

    private func debugPrintEntitlements() {
        NSLog("DEBUG_ENTITLEMENTS: Checking app bundle provisioning profile...")
        // Read embedded provisioning profile from app bundle (present in Ad-Hoc / Dev builds, stripped in TestFlight/AppStore)
        guard let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profileData = try? Data(contentsOf: profileURL) else {
            NSLog("DEBUG_ENTITLEMENTS: No embedded.mobileprovision found in bundle (Note: TestFlight/App Store builds strip this file)")
            return
        }

        // The mobileprovision file is CMS-signed; the plist is between <plist> tags
        guard let profileString = String(data: profileData, encoding: .ascii),
              let plistStart = profileString.range(of: "<?xml"),
              let plistEnd = profileString.range(of: "</plist>") else {
            NSLog("DEBUG_ENTITLEMENTS: Could not parse mobileprovision")
            return
        }

        let plistString = String(profileString[plistStart.lowerBound...plistEnd.upperBound])
        guard let plistData = plistString.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            NSLog("DEBUG_ENTITLEMENTS: Could not deserialize plist")
            return
        }

        NSLog("DEBUG_ENTITLEMENTS: Profile Name: %@", plist["Name"] as? String ?? "unknown")
        NSLog("DEBUG_ENTITLEMENTS: Team: %@", (plist["TeamIdentifier"] as? [String])?.joined(separator: ", ") ?? "unknown")
        NSLog("DEBUG_ENTITLEMENTS: AppIDName: %@", plist["AppIDName"] as? String ?? "unknown")
        NSLog("DEBUG_ENTITLEMENTS: ProvisionsAllDevices: %@", plist["ProvisionsAllDevices"] != nil ? "YES" : "NO")

        if let entitlements = plist["Entitlements"] as? [String: Any] {
            NSLog("DEBUG_ENTITLEMENTS: === Entitlements ===")
            for (key, value) in entitlements.sorted(by: { $0.key < $1.key }) {
                NSLog("DEBUG_ENTITLEMENTS:   %@ = %@", key, "\(value)")
            }
        } else {
            NSLog("DEBUG_ENTITLEMENTS: No Entitlements dict found in profile")
        }
    }

//    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
//        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
//    }
}
