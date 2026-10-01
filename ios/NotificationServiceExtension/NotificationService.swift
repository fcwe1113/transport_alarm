import UserNotifications
import Flutter

let appGroupId = "group.com.fcwe1113.busArrivalNotificationApp.66RCG95DR7"

class NotificationService: UNNotificationServiceExtension {
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?
    var flutterEngine: FlutterEngine?
    var timeoutWorkItem: DispatchWorkItem?

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

        guard let bestAttemptContent = bestAttemptContent,
              let pingIdRaw = request.content.userInfo["ping_id"] else {
            contentHandler(request.content)
            return
        }
        let pingId = String(describing: pingIdRaw)
        NSLog("DEBUG TEST: NSE stage 2")

        DispatchQueue.main.async {
            let frameworksPath = Bundle.main.bundlePath + "/Frameworks"
            let appFrameworkPath = frameworksPath + "/App.framework"
            let appFrameworkBundle = Bundle(path: appFrameworkPath)
            let flutterProject = FlutterDartProject(precompiledDartBundle: appFrameworkBundle)
            let engine = FlutterEngine(name: "notification_service", project: flutterProject, allowHeadlessExecution: true)
            self.flutterEngine = engine
            NSLog("DEBUG TEST: NSE stage 3")

            engine.run(withEntrypoint: "notificationServiceExtension", libraryURI: nil)
            NotificationServicePluginRegistrant.register(with: engine)

            let doneChannel = FlutterMethodChannel(name: "com.fcwe1113.busArrivalNotificationApp/nse", binaryMessenger: engine.binaryMessenger)
            doneChannel.setMethodCallHandler { (call, result) in
                if call.method == "done" {
                    self.finish(bestAttemptContent)
                }
                result(nil)
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

            doneChannel.invokeMethod("handlePing", arguments: pingId)

            // safety timeout, ahead of the OS's own ~30s NSE budget
            let workItem = DispatchWorkItem { self.finish(bestAttemptContent) }
            self.timeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: workItem)
        }
    }

    private func finish(_ content: UNMutableNotificationContent) {
        timeoutWorkItem?.cancel()
        flutterEngine?.destroyContext()
        flutterEngine = nil
        contentHandler?(content)
        contentHandler = nil
    }

    override func serviceExtensionTimeWillExpire() {
        if let bestAttemptContent = bestAttemptContent {
            finish(bestAttemptContent)
        }
    }
}
