import UserNotifications
import Flutter

let appGroupId = "group.com.fcwe1113.busArrivalNotificationApp.66RCG95DR7"

class NotificationService: UNNotificationServiceExtension {
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?
    var flutterEngine: FlutterEngine?
    var timeoutWorkItem: DispatchWorkItem?
    var pendingPingId: String?

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupId)
    }

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {

        if let container = AppGroup.containerURL {
            let testFile = container.appendingPathComponent("app_group_test.txt")
            do {
                let contents = try String(contentsOf: testFile, encoding: .utf8)
                NSLog("APP GROUP TEST: NSE read: \(contents)")
            } catch {
                NSLog("APP GROUP TEST: NSE read failed: \(error)")
            }
        } else {
            NSLog("APP GROUP TEST: containerURL is nil")
        }

        NSLog("DEBUG TEST: NSE stage 1")

        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let bestAttemptContent = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        // Temporary visible probe: if this appears, the extension ran and
        // successfully created mutable notification content. The Flutter
        // decision response should replace it later in this method.
        bestAttemptContent.title = "NSE DEBUG: mutable copy created"
        bestAttemptContent.body = "Waiting for the Flutter alarm decision."

        guard let pingId = Self.pingId(from: request.content.userInfo) else {
            // Keep this visible while validating APNs payload parsing. This is
            // more useful than NSLog when device logs aren't available.
            bestAttemptContent.title = "Ping could not be processed"
            bestAttemptContent.body = "The notification payload did not contain a readable ping_id."
            contentHandler(bestAttemptContent)
            return
        }
        NSLog("DEBUG TEST: NSE stage 2")

        DispatchQueue.main.async {
            let frameworksPath = Bundle.main.bundlePath + "/Frameworks"
            let appFrameworkPath = frameworksPath + "/App.framework"
            let appFrameworkBundle = Bundle(path: appFrameworkPath)
            let flutterProject = FlutterDartProject(precompiledDartBundle: appFrameworkBundle)
            let engine = FlutterEngine(name: "notification_service", project: flutterProject, allowHeadlessExecution: true)
            self.flutterEngine = engine
            self.pendingPingId = pingId
            NSLog("DEBUG TEST: NSE stage 3")

            // Install native handlers before Dart starts. Dart sends `ready`
            // after registering its own handler, so handlePing cannot race startup.
            let nseChannel = FlutterMethodChannel(
                name: "com.fcwe1113.transport_alarm/nse",
                binaryMessenger: engine.binaryMessenger
            )
            nseChannel.setMethodCallHandler { [weak self] call, result in
                guard let self else {
                    result(FlutterError(code: "extension_unavailable", message: nil, details: nil))
                    return
                }

                switch call.method {
                case "ready":
                    guard let pingId = self.pendingPingId else {
                        result(FlutterError(code: "missing_ping_id", message: nil, details: nil))
                        return
                    }
                    result(nil)
                    nseChannel.invokeMethod("handlePing", arguments: pingId)
                case "updateContent":
                    guard let values = call.arguments as? [String: Any] else {
                        result(FlutterError(code: "invalid_content", message: nil, details: nil))
                        return
                    }
                    if let title = values["title"] as? String {
                        bestAttemptContent.title = title
                    }
                    if let body = values["body"] as? String {
                        bestAttemptContent.body = body
                    }
                    result(nil)
                case "done":
                    result(nil)
                    DispatchQueue.main.async {
                        self.finish(bestAttemptContent)
                    }
                default:
                    result(FlutterMethodNotImplemented)
                }
            }

            let appGroupChannel = FlutterMethodChannel(
                name: "com.fcwe1113.transport_alarm/app_group",
                binaryMessenger: engine.binaryMessenger
            )
            appGroupChannel.setMethodCallHandler { call, result in
                if call.method == "containerPath" {
                    result(AppGroup.containerURL?.path)
                } else {
                    result(FlutterMethodNotImplemented)
                }
            }

            // wire AlarmKit onto this engine too — same handler logic as AppDelegate,
            // since this is a separate FlutterEngine instance with its own channels
            let alarmKitChannel = FlutterMethodChannel(name: "com.fcwe1113.busArrivalNotificationApp/alarmkit", binaryMessenger: engine.binaryMessenger)
            alarmKitChannel.setMethodCallHandler { (call, result) in
                // reuse the same armAlarm/cancelAlarm implementations from AppDelegate,
                // refactored into a shared helper both can call
                AlarmKitBridge.handle(call: call, result: result)
            }

            NotificationServicePluginRegistrant.register(with: engine)

            // safety timeout, ahead of the OS's own ~30s NSE budget
            let workItem = DispatchWorkItem { self.finish(bestAttemptContent) }
            self.timeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: workItem)

            engine.run(withEntrypoint: "notificationServiceExtension", libraryURI: nil)
        }
    }

    private func finish(_ content: UNMutableNotificationContent) {
        timeoutWorkItem?.cancel()
        flutterEngine?.destroyContext()
        flutterEngine = nil
        pendingPingId = nil
        contentHandler?(content)
        contentHandler = nil
    }

    private static func pingId(from userInfo: [AnyHashable: Any]) -> String? {
        let aps = userInfo["aps"] as? [String: Any]
        let data = userInfo["data"] as? [String: Any]
        let candidates: [Any?] = [
            userInfo["ping_id"],
            data?["ping_id"],
            aps?["ping_id"],
        ]

        for candidate in candidates {
            if let value = candidate as? String, !value.isEmpty {
                return value
            }
            if let value = candidate as? NSNumber {
                return value.stringValue
            }
        }
        return nil
    }

    override func serviceExtensionTimeWillExpire() {
        if let bestAttemptContent = bestAttemptContent {
            finish(bestAttemptContent)
        }
    }
}
