import foundation

enum AppGroup {
    static let identifier = "group.com.fcwe1113.busArrivalNotificationApp.66RCG95DR7"
    static var containerURL: URL? {FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)}
}