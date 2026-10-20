import Foundation

/// Applies a ring's Acknowledge action (or tap) to the shared alarm state:
/// moves the server ping on to the next threshold, to the next repeat, or
/// stops it for a finished one-off alarm. Changes are saved only once the
/// server has accepted them.
enum PingAcknowledgementHandler {
    private static let serverBaseURL = URL(string: "https://ios-scheduler.fcwe1113.workers.dev")!

    static func acknowledge(pingID: String) async {
        guard let directory = AppGroup.containerURL else { return }
        let alarmsURL = directory.appendingPathComponent("alarms.json")
        guard let data = try? Data(contentsOf: alarmsURL),
              var alarms = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let alarmIndex = alarms.firstIndex(where: { string($0["pingId"]) == pingID }) else { return }

        var alarm = alarms[alarmIndex]
        // The server requires the ping's secret to change it.
        guard let pingSecret = alarm["pingSecret"] as? String else { return }
        let alarmID = string(alarm["id"])
        var thresholds = alarm["thresholdStates"] as? [[String: Any]] ?? []
        guard let ringingIndex = thresholds.firstIndex(where: { $0["outcome"] as? String == "ringing" }) else { return }
        let currentThreshold = integer(thresholds[ringingIndex]["minutesBeforeArrival"]) ?? 0
        thresholds[ringingIndex]["outcome"] = "acknowledged"

        if let nextIndex = thresholds.indices.first(where: { $0 > ringingIndex && thresholds[$0]["outcome"] as? String == "pending" }) {
            let nextThreshold = integer(thresholds[nextIndex]["minutesBeforeArrival"]) ?? 0
            let minutesUntilCurrentThreshold = integer(alarm["lastEstimatedMinutesUntilThreshold"])
            let minutesUntilNext = minutesUntilCurrentThreshold.map {
                $0 + currentThreshold - nextThreshold
            }
            let delayMinutes: Int
            if let minutesUntilNext, minutesUntilNext > 5 {
                delayMinutes = max(1, Int((Double(minutesUntilNext) / 2).rounded()))
            } else if let minutesUntilNext {
                delayMinutes = max(1, minutesUntilNext)
            } else {
                delayMinutes = 1
            }

            do {
                try await reschedule(
                    pingID: pingID,
                    secret: pingSecret,
                    alarmID: alarmID,
                    at: Date().addingTimeInterval(TimeInterval(delayMinutes * 60)),
                    requireAck: minutesUntilNext.map { $0 <= 5 } ?? false
                )
                alarm["thresholdStates"] = thresholds
                if let minutesUntilNext {
                    alarm["lastEstimatedMinutesUntilThreshold"] = minutesUntilNext
                }
                alarms[alarmIndex] = alarm
                try save(alarms, to: alarmsURL)
            } catch {
                NSLog("Ping acknowledgement could not schedule the next threshold: %@", error.localizedDescription)
            }
            return
        }

        if let nextRepeat = nextRepeatDate(for: alarm) {
            do {
                try await reschedule(pingID: pingID, secret: pingSecret, alarmID: alarmID, at: nextRepeat, requireAck: false)
                alarm["thresholdStates"] = thresholds
                alarm["spent"] = true
                alarm["lastEstimatedMinutesUntilThreshold"] = NSNull()
                alarms[alarmIndex] = alarm
                try save(alarms, to: alarmsURL)
            } catch {
                NSLog("Ping acknowledgement could not schedule the next repeat: %@", error.localizedDescription)
            }
            return
        }

        do {
            if let alarmID { PingWatchdog.disarm(alarmID: alarmID) }
            try await acknowledgeOnServer(pingID: pingID, secret: pingSecret)
            alarm["thresholdStates"] = thresholds
            alarm["enabled"] = false
            alarm["spent"] = true
            alarm["pingId"] = NSNull()
            alarms[alarmIndex] = alarm
            try save(alarms, to: alarmsURL)
        } catch {
            NSLog("Ping acknowledgement could not stop the server ping: %@", error.localizedDescription)
        }
    }

    private static func reschedule(pingID: String, secret: String, alarmID: String?, at date: Date, requireAck: Bool) async throws {
        var request = URLRequest(url: serverBaseURL.appendingPathComponent("reschedule"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "ping_id": pingID,
            "ping_secret": secret,
            // A delay rather than a time, so the server uses its own clock.
            "delay_seconds": max(0, Int(date.timeIntervalSinceNow.rounded())),
            "require_ack": requireAck,
            "expire_on": NSNull(),
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw NSError(domain: "PingAcknowledgement", code: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        if let alarmID { await PingWatchdog.arm(alarmID: alarmID, nextPingAt: date) }
    }

    private static func acknowledgeOnServer(pingID: String, secret: String) async throws {
        var request = URLRequest(url: serverBaseURL.appendingPathComponent("ack"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ping_id": pingID, "ping_secret": secret])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw NSError(domain: "PingAcknowledgement", code: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    /// The start of a repeating alarm's next occurrence, or nil for a one-off
    /// alarm. Uses the same window and repeat-day rules as the extension.
    private static func nextRepeatDate(for alarm: [String: Any]) -> Date? {
        guard let window = AlarmWindow(alarm: alarm), window.frequency != "none" else { return nil }
        return window.nextOccurrence(after: Date(), calendar: NativeTransitLocales.gregorianCalendar())?.start
    }

    private static func save(_ alarms: [[String: Any]], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: alarms, options: [.sortedKeys])
        try data.write(to: url, options: [.atomic])
    }

    private static func integer(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}
