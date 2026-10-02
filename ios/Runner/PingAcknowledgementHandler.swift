import Foundation

/// Applies the notification's Acknowledge action to shared alarm state and
/// either advances to the next threshold or stops/repeats the alarm ping.
enum PingAcknowledgementHandler {
    private static let serverBaseURL = URL(string: "https://ios-scheduler.fcwe1113.workers.dev")!

    static func acknowledge(pingID: String) async {
        guard let directory = AppGroup.containerURL else { return }
        let alarmsURL = directory.appendingPathComponent("alarms.json")
        guard let data = try? Data(contentsOf: alarmsURL),
              var alarms = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let alarmIndex = alarms.firstIndex(where: { string($0["pingId"]) == pingID }) else { return }

        var alarm = alarms[alarmIndex]
        var thresholds = alarm["thresholdStates"] as? [[String: Any]] ?? []
        guard let ringingIndex = thresholds.firstIndex(where: { $0["outcome"] as? String == "ringing" }) else { return }
        let currentThreshold = integer(thresholds[ringingIndex]["minutesBeforeArrival"]) ?? 0
        thresholds[ringingIndex]["outcome"] = "acknowledged"

        if let nextIndex = thresholds.indices.first(where: { $0 > ringingIndex && thresholds[$0]["outcome"] as? String == "pending" }) {
            let nextThreshold = integer(thresholds[nextIndex]["minutesBeforeArrival"]) ?? 0
            let minutesUntilCurrentThreshold = integer(alarm["lastEstimatedMinutesUntilThreshold"])
                ?? integer(alarm["lastEstimatedMinutesUntilArrival"]).map { $0 - currentThreshold }
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
                    at: Date().addingTimeInterval(TimeInterval(delayMinutes * 60)),
                    requireAck: minutesUntilNext.map { $0 <= 5 } ?? false
                )
                alarm["thresholdStates"] = thresholds
                if let minutesUntilNext {
                    alarm["lastEstimatedMinutesUntilThreshold"] = minutesUntilNext
                    alarm.removeValue(forKey: "lastEstimatedMinutesUntilArrival")
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
                try await reschedule(pingID: pingID, at: nextRepeat, requireAck: false)
                alarm["thresholdStates"] = thresholds
                alarm["spent"] = true
                alarm["lastEstimatedMinutesUntilThreshold"] = NSNull()
                alarm.removeValue(forKey: "lastEstimatedMinutesUntilArrival")
                alarms[alarmIndex] = alarm
                try save(alarms, to: alarmsURL)
            } catch {
                NSLog("Ping acknowledgement could not schedule the next repeat: %@", error.localizedDescription)
            }
            return
        }

        do {
            try await acknowledgeOnServer(pingID: pingID)
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

    private static func reschedule(pingID: String, at date: Date, requireAck: Bool) async throws {
        var request = URLRequest(url: serverBaseURL.appendingPathComponent("reschedule"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "ping_id": pingID,
            "scheduled_time": Int(date.timeIntervalSince1970),
            "require_ack": requireAck,
            "expire_on": NSNull(),
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw NSError(domain: "PingAcknowledgement", code: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    private static func acknowledgeOnServer(pingID: String) async throws {
        var request = URLRequest(url: serverBaseURL.appendingPathComponent("ack"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ping_id": pingID])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw NSError(domain: "PingAcknowledgement", code: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    private static func nextRepeatDate(for alarm: [String: Any]) -> Date? {
        let repeatInfo = alarm["repeat"] as? [String: Any] ?? [:]
        let frequency = repeatInfo["frequency"] as? String ?? "none"
        let windowStart = integer(alarm["windowStart"]) ?? 0
        var calendar = NativeTransitLocales.gregorianCalendar(for: alarm)
        let now = Date()
        let today = calendar.startOfDay(for: now)

        switch frequency {
        case "daily":
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
            return NativeTransitLocales.date(windowStartMinutes: windowStart, on: nextDay, calendar: calendar)
        case "weekly":
            let weekdays = Set(repeatInfo["weekdays"] as? [Int] ?? [])
            for offset in 1...7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
                let weekday = calendar.component(.weekday, from: day)
                let dartWeekday = weekday == 1 ? 7 : weekday - 1
                if weekdays.contains(dartWeekday) {
                    return NativeTransitLocales.date(windowStartMinutes: windowStart, on: day, calendar: calendar)
                }
            }
        case "monthly":
            let days = Set(repeatInfo["dayOfMonth"] as? [Int] ?? [])
            for offset in 1...370 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
                if days.contains(calendar.component(.day, from: day)) {
                    return NativeTransitLocales.date(windowStartMinutes: windowStart, on: day, calendar: calendar)
                }
            }
        default:
            return nil
        }
        return nil
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
