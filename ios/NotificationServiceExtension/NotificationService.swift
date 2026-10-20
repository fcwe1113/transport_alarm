import Foundation
import UserNotifications

/// Runs for every alarm ping push: hands the ping to NativePingHandler, then
/// replaces the push's placeholder text with what the ping did. Gives up
/// with a timeout notice after 24 seconds, before iOS's own limit.
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
        guard bestAttemptContent != nil else {
            contentHandler(request.content)
            return
        }

        guard let pingID = Self.pingID(from: request.content.userInfo) else {
            finish(title: NativeLocalization.text("native.update_unavailable.title"),
                   body: NativeLocalization.text("native.update_unavailable.ping"),
                   style: .problem)
            return
        }
        guard let container = AppGroup.containerURL else {
            finish(title: NativeLocalization.text("native.update_unavailable.title"),
                   body: NativeLocalization.text("native.update_unavailable.storage"),
                   style: .problem)
            return
        }

        let timeout = DispatchWorkItem { [weak self] in self?.finishWithTimeout() }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 24, execute: timeout)

        processingTask = Task { [weak self] in
            let result = await NativePingHandler(appGroupDirectory: container).handle(pingID: pingID)
            guard !Task.isCancelled else { return }
            self?.finish(title: result.title, body: result.body, style: result.style, category: result.categoryIdentifier)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        finishWithTimeout()
    }

    private func finishWithTimeout() {
        finish(title: NativeLocalization.text("native.update_timeout.title"),
               body: NativeLocalization.text("native.update_timeout.body"),
               style: .problem)
    }

    /// Shows the notice once. Everything happens on the main queue, so the
    /// ping's result and the timeout can't both write the notification.
    private func finish(title: String, body: String, style: PingAlertStyle, category: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasFinished, let content = self.bestAttemptContent else { return }
            self.hasFinished = true
            self.timeoutWorkItem?.cancel()
            self.processingTask?.cancel()
            content.title = title
            content.body = body
            content.categoryIdentifier = category ?? ""
            Self.apply(style, to: content)
            self.contentHandler?(content)
            self.contentHandler = nil
            self.bestAttemptContent = nil
        }
    }

    /// The ping ID the Worker puts at the payload's top level, also accepted
    /// under "data" or "aps".
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

    /// Sets the sound and interruption level for a notice. The Worker sends
    /// pings without a sound, so updates stay silent unless chosen here.
    private static func apply(_ style: PingAlertStyle, to content: UNMutableNotificationContent) {
        switch style {
        case .update:
            content.sound = nil
            content.interruptionLevel = .passive
        case .problem:
            content.sound = .default
            content.interruptionLevel = .active
        case .ring:
            // Bundled in the app (Runner/ring.caf); iOS plays up to 30 seconds.
            content.sound = UNNotificationSound(named: UNNotificationSoundName("ring.caf"))
            content.interruptionLevel = .timeSensitive
        }
    }
}
