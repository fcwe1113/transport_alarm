import AlarmKit
import CryptoKit
import SwiftUI

enum AlarmKitScheduler {
    static func stableID(for alarmID: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(alarmID.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func schedule(alarmID: UUID, secondsUntilFire: TimeInterval, title: String) async throws {
        // Permission is requested from the foreground app when the alarm is
        // created. Push handling runs in an extension, where requesting a new
        // user authorization can fail because there is no foreground UI.
        let authorizationState = AlarmManager.shared.authorizationState
        guard authorizationState == .authorized else {
            throw SchedulerError.notAuthorized(String(describing: authorizationState))
        }

        typealias Configuration = AlarmManager.AlarmConfiguration<TransportAlarmMetadata>
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: title),
            secondaryButton: nil,
            secondaryButtonBehavior: nil
        )
        // Declaring a countdown presentation makes AlarmKit use the widget extension
        // for the pre-alert Live Activity associated with this countdown duration.
        let countdown = AlarmPresentation.Countdown(
            title: LocalizedStringResource(stringLiteral: title)
        )
        let presentation = AlarmPresentation(alert: alert, countdown: countdown, paused: nil)
        let attributes = AlarmAttributes<TransportAlarmMetadata>(
            presentation: presentation,
            metadata: nil,
            tintColor: .blue
        )
        let duration = Alarm.CountdownDuration(preAlert: max(1, secondsUntilFire), postAlert: nil)
        let configuration = Configuration(countdownDuration: duration, attributes: attributes)
        do {
            _ = try await AlarmManager.shared.schedule(id: alarmID, configuration: configuration)
        } catch {
            throw SchedulerError.scheduleFailed(Self.describe(error))
        }
    }

    static func requestAuthorization() async throws -> Bool {
        let state = try await AlarmManager.shared.requestAuthorization()
        return state == .authorized
    }

    static func cancel(alarmID: UUID) throws {
        try AlarmManager.shared.cancel(id: alarmID)
    }

    /// Keeps the failing AlarmKit phase and underlying NSError details in the
    /// notification text, where extension-process logs may not be available.
    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) code \(nsError.code): \(nsError.localizedDescription)"
    }

    enum SchedulerError: LocalizedError {
        case notAuthorized(String)
        case scheduleFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized(let state):
                "AlarmKit authorization is not granted (state: \(state))."
            case .scheduleFailed(let details):
                "AlarmKit schedule call failed: \(details)"
            }
        }
    }
}
