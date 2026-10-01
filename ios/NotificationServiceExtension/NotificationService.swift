import Foundation
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var timeoutWorkItem: DispatchWorkItem?
    private var processingTask: Task<Void, Never>?
    private var hasFinished = false

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let content = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        guard let pingID = Self.pingID(from: request.content.userInfo) else {
            content.title = "Alarm update unavailable"
            content.body = "The notification did not include an alarm ping identifier."
            finish(content)
            return
        }

        guard let container = AppGroup.containerURL else {
            content.title = "Alarm update unavailable"
            content.body = "The shared alarm data folder could not be opened."
            finish(content)
            return
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, let content = self.bestAttemptContent else { return }
            content.title = "Alarm update timed out"
            content.body = "The alarm update took too long."
            self.finish(content)
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 24, execute: timeout)

        processingTask = Task { [weak self] in
            guard let self else { return }
            let result = await NativePingHandler(appGroupDirectory: container).handle(pingID: pingID)
            guard !Task.isCancelled, let content = self.bestAttemptContent else { return }
            content.title = result.title
            content.body = result.body
            self.finish(content)
        }
    }

    private func finish(_ content: UNMutableNotificationContent) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasFinished else { return }
            self.hasFinished = true
            self.timeoutWorkItem?.cancel()
            self.processingTask?.cancel()
            self.contentHandler?(content)
            self.contentHandler = nil
            self.bestAttemptContent = nil
        }
    }

    private static func pingID(from userInfo: [AnyHashable: Any]) -> String? {
        let aps = userInfo["aps"] as? [String: Any]
        let data = userInfo["data"] as? [String: Any]
        let candidates: [Any?] = [userInfo["ping_id"], data?["ping_id"], aps?["ping_id"]]
        for candidate in candidates {
            if let value = candidate as? String, !value.isEmpty { return value }
            if let value = candidate as? NSNumber { return value.stringValue }
        }
        return nil
    }

    override func serviceExtensionTimeWillExpire() {
        guard let content = bestAttemptContent else { return }
        content.title = "Alarm update timed out"
        content.body = "The alarm update took too long."
        finish(content)
    }
}
