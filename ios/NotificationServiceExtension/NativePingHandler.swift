import Foundation
import SQLite3

private struct OperatorStop {
    let provider: String
    let stopID: String
}

struct PingResult {
    let title: String
    let body: String
    let debugMessage: String?
    let categoryIdentifier: String?

    init(title: String, body: String, debugMessage: String? = nil, categoryIdentifier: String? = nil) {
        self.title = title
        self.body = body
        self.debugMessage = debugMessage
        self.categoryIdentifier = categoryIdentifier
    }
}

private enum PingHandlerError: Error {
    case invalidAlarmData
    case serverRejected(Int)
}

/// Implements the iOS ping path without starting Flutter or loading its plugins.
/// It reads the shared alarm data, updates the next threshold/repeat, and returns
/// replacement notification text to the Notification Service Extension.
final class NativePingHandler {
    private let appGroupDirectory: URL
    private let serverBaseURL = URL(string: "https://ios-scheduler.fcwe1113.workers.dev")!

    init(appGroupDirectory: URL) {
        self.appGroupDirectory = appGroupDirectory
    }

    /// Processes one server ping. A visible push is the ring itself; the same
    /// server ping ID is rescheduled until the user acknowledges the threshold.
    func handle(pingID: String) async -> PingResult {
        do {
            var alarms = try loadAlarms()
            guard let alarmIndex = alarms.firstIndex(where: {
                Self.stringValue($0["pingId"]) == pingID
            }) else {
                try? await acknowledge(pingID: pingID)
                return PingResult(title: "Alarm no longer active", body: "This alarm is no longer enabled.")
            }

            var alarm = alarms[alarmIndex]
            guard (alarm["enabled"] as? Bool) != false else {
                try? await acknowledge(pingID: pingID)
                return PingResult(title: "Alarm is disabled", body: "No alarm action is needed. \(Self.alarmDebugJSON(alarm))")
            }

            var thresholdStates = (alarm["thresholdStates"] as? [[String: Any]] ?? []).sorted {
                (Self.intValue($0["minutesBeforeArrival"]) ?? 0) >
                    (Self.intValue($1["minutesBeforeArrival"]) ?? 0)
            }

            // A scheduled ping at the next repeat start begins a fresh occurrence.
            if alarm["spent"] as? Bool == true {
                if repeatFrequency(of: alarm) == "none" {
                    alarm["enabled"] = false
                    alarm["pingId"] = NSNull()
                    alarms[alarmIndex] = alarm
                    try saveAlarms(alarms)
                    try? await acknowledge(pingID: pingID)
                    return PingResult(title: "Alarm complete", body: "This alarm has already finished.")
                }
                for index in thresholdStates.indices {
                    thresholdStates[index]["outcome"] = "pending"
                    thresholdStates[index]["ringCount"] = 0
                }
                alarm["thresholdStates"] = thresholdStates
                alarm["spent"] = false
                alarm["lastEstimatedMinutesUntilThreshold"] = NSNull()
                alarm.removeValue(forKey: "lastEstimatedMinutesUntilArrival")
                alarms[alarmIndex] = alarm
                try saveAlarms(alarms)
            }

            alarm["thresholdStates"] = thresholdStates
            guard let activeIndex = thresholdStates.firstIndex(where: {
                let outcome = $0["outcome"] as? String
                return outcome == "pending" || outcome == "ringing"
            }) else {
                if repeatFrequency(of: alarm) != "none" {
                    let nextRepeat = try nextRepeatDate(for: alarm)
                    try await reschedule(pingID: pingID, at: nextRepeat, requireAck: false)
                    alarm["thresholdStates"] = thresholdStates
                    alarm["spent"] = true
                    alarm["lastEstimatedMinutesUntilThreshold"] = NSNull()
                    alarm.removeValue(forKey: "lastEstimatedMinutesUntilArrival")
                    alarms[alarmIndex] = alarm
                    try saveAlarms(alarms)
                    return PingResult(title: "Next alarm occurrence scheduled", body: "The next repeat is scheduled.")
                }
                alarm["enabled"] = false
                alarm["spent"] = true
                alarm["pingId"] = NSNull()
                alarms[alarmIndex] = alarm
                try saveAlarms(alarms)
                try? await acknowledge(pingID: pingID)
                return PingResult(title: "Alarm complete", body: "All alarm thresholds are complete.")
            }

            // Use a fresh arrival estimate when available, otherwise retain the
            // last good value so a transient API failure does not stop the alarm.
            guard let thresholdMinutes = Self.intValue(thresholdStates[activeIndex]["minutesBeforeArrival"]) else {
                throw PingHandlerError.invalidAlarmData
            }
            let cachedEstimateUntilThreshold = Self.intValue(alarm["lastEstimatedMinutesUntilThreshold"])
                ?? Self.intValue(alarm["lastEstimatedMinutesUntilArrival"]).map { $0 - thresholdMinutes }
            if (alarm["routeApiConfigs"] as? [[String: Any]] ?? []).isEmpty {
                let alarmLocale = NativeTransitLocales.locale(for: alarm["localeCode"] as? String)
                let configs = routeAPIConfigsForLegacyAlarm(alarm, locale: alarmLocale)
                if !configs.isEmpty {
                    alarm["routeApiConfigs"] = configs
                    alarms[alarmIndex] = alarm
                    try saveAlarms(alarms)
                }
            }
            let isFreshOccurrence = cachedEstimateUntilThreshold == nil &&
                !thresholdStates.isEmpty &&
                thresholdStates.allSatisfy { ($0["outcome"] as? String ?? "pending") == "pending" }
            let minimumArrivalMinutes = isFreshOccurrence
                ? thresholdStates.compactMap { Self.intValue($0["minutesBeforeArrival"]) }.max()
                : nil
            let freshArrivalEstimate = await estimateMinutesUntilArrival(
                for: alarm,
                minimumArrivalMinutes: minimumArrivalMinutes
            )
            let freshEstimateUntilThreshold = freshArrivalEstimate.map { $0 - thresholdMinutes }
            let estimateUntilThreshold = freshEstimateUntilThreshold ?? cachedEstimateUntilThreshold
            if let freshEstimateUntilThreshold {
                alarm["lastEstimatedMinutesUntilThreshold"] = freshEstimateUntilThreshold
                alarm.removeValue(forKey: "lastEstimatedMinutesUntilArrival")
            }

            // Once a threshold is ringing, keep sending the same visible push
            // every minute until its notification action acknowledges it.
            if thresholdStates[activeIndex]["outcome"] as? String == "ringing" {
                do {
                    try await reschedule(pingID: pingID, at: Date().addingTimeInterval(60), requireAck: true)
                    alarm["thresholdStates"] = thresholdStates
                    if let freshEstimateUntilThreshold {
                        alarm["lastEstimatedMinutesUntilThreshold"] = freshEstimateUntilThreshold
                        alarm.removeValue(forKey: "lastEstimatedMinutesUntilArrival")
                    }
                    alarms[alarmIndex] = alarm
                    try saveAlarms(alarms)
                    return ringResult(alarm: alarm, thresholdMinutes: thresholdMinutes)
                } catch {
                    return ringResult(alarm: alarm, thresholdMinutes: thresholdMinutes, debugMessage: "Next ping scheduling failed: \(Self.describe(error))")
                }
            }

            guard let estimateUntilThreshold else {
                let retryAt = Date().addingTimeInterval(5 * 60)
                try await reschedule(pingID: pingID, at: retryAt, requireAck: false)
                alarms[alarmIndex] = alarm
                try saveAlarms(alarms)
                return PingResult(title: "Arrival estimate unavailable", body: "Another update is scheduled in 5 minutes.")
            }

            if estimateUntilThreshold > 5 {
                // Recheck halfway through the remaining time to this threshold.
                let delayMinutes = max(1, Int((Double(estimateUntilThreshold) / 2).rounded()))
                try await reschedule(
                    pingID: pingID,
                    at: Date().addingTimeInterval(TimeInterval(delayMinutes * 60)),
                    requireAck: false
                )
                alarm["thresholdStates"] = thresholdStates
                alarms[alarmIndex] = alarm
                try saveAlarms(alarms)
                return PingResult(
                    title: "Alarm update scheduled",
                    body: "The threshold is about \(estimateUntilThreshold) minutes away. Another check is scheduled in \(delayMinutes) minutes."
                )
            }

            if estimateUntilThreshold > 0 {
                try await reschedule(
                    pingID: pingID,
                    at: Date().addingTimeInterval(TimeInterval(estimateUntilThreshold * 60)),
                    requireAck: true
                )
                alarm["thresholdStates"] = thresholdStates
                alarms[alarmIndex] = alarm
                try saveAlarms(alarms)
                return PingResult(title: "Alarm approaching", body: "The alarm will ring in \(estimateUntilThreshold) minutes.")
            }

            thresholdStates[activeIndex]["outcome"] = "ringing"
            let oldCount = Self.intValue(thresholdStates[activeIndex]["ringCount"]) ?? 0
            thresholdStates[activeIndex]["ringCount"] = oldCount + 1
            alarm["thresholdStates"] = thresholdStates
            alarms[alarmIndex] = alarm
            try? saveAlarms(alarms)
            do {
                try await reschedule(pingID: pingID, at: Date().addingTimeInterval(60), requireAck: true)
                return ringResult(alarm: alarm, thresholdMinutes: thresholdMinutes)
            } catch {
                return ringResult(alarm: alarm, thresholdMinutes: thresholdMinutes, debugMessage: "Next ping scheduling failed: \(Self.describe(error))")
            }
        } catch {
            return PingResult(title: "Alarm update failed", body: "The existing notification schedule could not be updated.")
        }
    }

    private func ringResult(alarm: [String: Any], thresholdMinutes: Int, debugMessage: String? = nil) -> PingResult {
        let title = (alarm["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Bus arriving soon"
        return PingResult(
            title: title,
            body: "Your bus alarm has reached its \(thresholdMinutes)-minute threshold. Acknowledge to continue.",
            debugMessage: debugMessage,
            categoryIdentifier: "transport_alarm_ring"
        )
    }

    // MARK: Shared alarm data

    /// Returns the alarms JSON file in the shared App Group container.

    private var alarmsFile: URL {
        appGroupDirectory.appendingPathComponent("alarms.json")
    }

    /// Reads the serialized alarm list used by both the app and extension.
    private func loadAlarms() throws -> [[String: Any]] {
        let data = try Data(contentsOf: alarmsFile, options: [.mappedIfSafe])
        guard let alarms = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PingHandlerError.invalidAlarmData
        }
        return alarms
    }

    /// Atomically writes the updated alarm list so an interrupted write does not
    /// leave partially serialized state for the app or a later extension run.
    private func saveAlarms(_ alarms: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: alarms, options: [.sortedKeys])
        try data.write(to: alarmsFile, options: [.atomic])
    }

    /// Reads the repeat mode, treating a missing repeat configuration as one-shot.
    private func repeatFrequency(of alarm: [String: Any]) -> String {
        let repeatInfo = alarm["repeat"] as? [String: Any]
        return repeatInfo?["frequency"] as? String ?? "none"
    }

    // MARK: Arrival estimate (GTFS SQLite plus provider APIs)

    /// Finds the earliest matching live ETA through registered operators. If no
    /// live result exists, uses the GTFS schedule unless the alarm is live-only.
    private func estimateMinutesUntilArrival(
        for alarm: [String: Any],
        minimumArrivalMinutes: Int?
    ) async -> Int? {
        guard let stopID = alarm["gtfsStopId"] as? String,
              let routeNumbers = alarm["routeNumbers"] as? [String],
              !routeNumbers.isEmpty else {
            return nil
        }

        let locale = NativeTransitLocales.locale(for: alarm["localeCode"] as? String)
        let savedRouteConfigs = alarm["routeApiConfigs"] as? [[String: Any]] ?? []
        let requests: [NativeTransitETARequest] = savedRouteConfigs.compactMap { config -> NativeTransitETARequest? in
            guard let mode = config["mode"] as? String,
                  let providerCode = config["providerCode"] as? String,
                  let apiURL = config["apiUrl"] as? String else {
                return nil
            }
            return NativeTransitETAProviders.request(
                mode: mode,
                providerCode: providerCode,
                apiURL: apiURL
            )
        }

        let liveDates = requests.isEmpty ? [] : await fetchLiveETAs(from: requests, allowedRoutes: Set(routeNumbers))
        let eligibleLiveDates = liveDates.filter { date in
            guard let minimumArrivalMinutes else { return true }
            return Int(date.timeIntervalSinceNow / 60) >= minimumArrivalMinutes
        }
        if let earliest = eligibleLiveDates.min() {
            return Int(earliest.timeIntervalSinceNow / 60)
        }
        if alarm["liveOnly"] as? Bool == true {
            return nil
        }
        return scheduledMinutesUntilArrival(
            stopID: stopID,
            routeNumbers: routeNumbers,
            locale: locale,
            minimumArrivalMinutes: minimumArrivalMinutes
        )
    }

    /// Migrates older alarm records once by saving the provider URL for each
    /// selected route. New alarms already contain these values at creation.
    private func routeAPIConfigsForLegacyAlarm(
        _ alarm: [String: Any],
        locale: NativeTransitLocale
    ) -> [[String: Any]] {
        guard let stopID = alarm["gtfsStopId"] as? String,
              let routeNumbers = alarm["routeNumbers"] as? [String] else {
            return []
        }
        let stops = operatorStops(for: stopID, locale: locale) ?? []
        var configs: [[String: Any]] = []
        for stop in stops {
            for routeNumber in routeNumbers {
                guard let request = NativeTransitETAProviders.legacyRequest(
                    providerCode: stop.provider,
                    stopID: stop.stopID,
                    routeNumber: routeNumber
                ) else { continue }
                configs.append([
                    "routeNumber": routeNumber,
                    "mode": request.mode,
                    "providerCode": request.providerCode,
                    "apiUrl": request.url.absoluteString,
                ])
            }
        }
        return configs
    }

    /// Looks up the operator-specific stop IDs mapped to a GTFS stop in the
    /// bundled database stored in the shared App Group directory.
    private func operatorStops(for gtfsStopID: String, locale: NativeTransitLocale) -> [OperatorStop]? {
        let databaseURL = appGroupDirectory.appendingPathComponent(locale.databaseRelativePath)
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_exec(database, "PRAGMA cache_size=-512; PRAGMA mmap_size=0;", nil, nil, nil)

        let sql = """
            SELECT sm.operator_stop_id, os.provider_code
            FROM stop_mapping sm
            INNER JOIN operator_stops os ON os.operator_stop_id = sm.operator_stop_id
            WHERE sm.gtfs_stop_id = ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        bind(gtfsStopID, to: statement, at: 1)

        var stops: [OperatorStop] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(statement, 0),
                  let providerPointer = sqlite3_column_text(statement, 1) else { continue }
            let operatorID = String(cString: idPointer)
            let provider = String(cString: providerPointer)
            let operatorIDParts = operatorID.split(separator: ":", maxSplits: 1)
            guard operatorIDParts.count == 2 else { continue }
            let rawID = String(operatorIDParts[1])
            if !rawID.isEmpty {
                stops.append(OperatorStop(provider: provider, stopID: rawID))
            }
        }
        return stops
    }

    /// Queries today's GTFS service calendar and stop times for the next arrival
    /// matching the selected routes and stop.
    private func scheduledMinutesUntilArrival(
        stopID: String,
        routeNumbers: [String],
        locale: NativeTransitLocale,
        minimumArrivalMinutes: Int?
    ) -> Int? {
        guard !routeNumbers.isEmpty else { return nil }
        let databaseURL = appGroupDirectory.appendingPathComponent(locale.databaseRelativePath)
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_exec(database, "PRAGMA cache_size=-512; PRAGMA mmap_size=0;", nil, nil, nil)

        var calendar = locale.gregorianCalendar
        let now = Date()
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: now)
        guard let year = components.year, let month = components.month,
              let day = components.day, let weekday = components.weekday else { return nil }
        let weekdayColumns = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let weekdayColumn = weekdayColumns[weekday - 1]
        let dateString = String(format: "%04d%02d%02d", year, month, day)
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = locale.timeZone
        timeFormatter.dateFormat = "HH:mm:ss"
        let localTime = timeFormatter.string(from: now)
        let placeholders = Array(repeating: "?", count: routeNumbers.count).joined(separator: ",")
        let sql = """
            SELECT st.arrival_time
            FROM gtfs_stop_times st
            INNER JOIN gtfs_trips t ON st.trip_id = t.trip_id
            INNER JOIN gtfs_routes r ON t.route_id = r.route_id
            INNER JOIN gtfs_calendar c ON t.service_id = c.service_id
            WHERE st.stop_id = ? AND r.route_short_name IN (\(placeholders))
              AND st.arrival_time > ? AND c.\(weekdayColumn) = 1
              AND c.start_date <= ? AND c.end_date >= ?
            ORDER BY st.arrival_time ASC LIMIT 50
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(stopID, to: statement, at: 1)
        for (offset, route) in routeNumbers.enumerated() {
            bind(route, to: statement, at: Int32(offset + 2))
        }
        let timeBinding = Int32(routeNumbers.count + 2)
        bind(localTime, to: statement, at: timeBinding)
        bind(dateString, to: statement, at: timeBinding + 1)
        bind(dateString, to: statement, at: timeBinding + 2)

        let startOfDay = calendar.startOfDay(for: now)
        var soonest: Int?
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let timePointer = sqlite3_column_text(statement, 0) else { continue }
            let pieces = String(cString: timePointer).split(separator: ":").compactMap { Int($0) }
            guard pieces.count == 3 else { continue }
            let departure = startOfDay.addingTimeInterval(TimeInterval(pieces[0] * 3600 + pieces[1] * 60 + pieces[2]))
            let minutes = Int(departure.timeIntervalSince(now) / 60)
            let meetsThreshold = minimumArrivalMinutes.map { minutes >= $0 } ?? true
            if minutes >= 0, meetsThreshold, soonest == nil || minutes < soonest! {
                soonest = minutes
            }
        }
        return soonest
    }

    /// Fetches at most 24 operator/route endpoints, keeping no more than six
    /// network requests active at once to bound extension work and memory use.
    private func fetchLiveETAs(from requests: [NativeTransitETARequest], allowedRoutes: Set<String>) async -> [Date] {
        await withTaskGroup(of: [Date].self, returning: [Date].self) { group in
            var iterator = requests.prefix(24).makeIterator()
            for _ in 0..<min(6, requests.count) {
                if let request = iterator.next() {
                    group.addTask { await Self.fetchLiveETA(request: request, allowedRoutes: allowedRoutes) }
                }
            }

            var dates: [Date] = []
            while let result = await group.next() {
                dates.append(contentsOf: result)
                if let request = iterator.next() {
                    group.addTask { await Self.fetchLiveETA(request: request, allowedRoutes: allowedRoutes) }
                }
            }
            return dates
        }
    }

    /// Performs one API request and delegates its response decoding to the
    /// matching operator provider. Failed or non-200 responses produce no ETAs.
    private static func fetchLiveETA(request: NativeTransitETARequest, allowedRoutes: Set<String>) async -> [Date] {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.timeoutInterval = 3
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            return NativeTransitETAProviders.arrivalDates(
                from: data,
                providerCode: request.providerCode,
                matching: allowedRoutes
            )
        } catch {
            return []
        }
    }

    // MARK: Alarm schedule and server ping

    /// Calculates the next calendar occurrence in the alarm's locale for a
    /// daily, weekly, or monthly repeating alarm.
    private func nextRepeatDate(for alarm: [String: Any]) throws -> Date {
        let repeatInfo = alarm["repeat"] as? [String: Any] ?? [:]
        let frequency = repeatInfo["frequency"] as? String ?? "none"
        guard let windowStart = Self.intValue(alarm["windowStart"]) else {
            throw PingHandlerError.invalidAlarmData
        }
        let calendar = NativeTransitLocales.gregorianCalendar()
        let now = Date()
        let today = calendar.startOfDay(for: now)

        switch frequency {
        case "daily":
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: today) else {
                throw PingHandlerError.invalidAlarmData
            }
            guard let nextDate = NativeTransitLocales.date(
                windowStartMinutes: windowStart,
                on: nextDay,
                calendar: calendar
            ) else {
                throw PingHandlerError.invalidAlarmData
            }
            return nextDate
        case "weekly":
            let selectedDays = Set(repeatInfo["weekdays"] as? [Int] ?? [])
            for offset in 1...7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
                let weekday = calendar.component(.weekday, from: day)
                let dartWeekday = weekday == 1 ? 7 : weekday - 1
                if selectedDays.contains(dartWeekday) {
                    if let nextDate = NativeTransitLocales.date(
                        windowStartMinutes: windowStart,
                        on: day,
                        calendar: calendar
                    ) {
                        return nextDate
                    }
                }
            }
            throw PingHandlerError.invalidAlarmData
        case "monthly":
            let selectedDays = Set(repeatInfo["dayOfMonth"] as? [Int] ?? [])
            for offset in 1...370 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
                if selectedDays.contains(calendar.component(.day, from: day)) {
                    if let nextDate = NativeTransitLocales.date(
                        windowStartMinutes: windowStart,
                        on: day,
                        calendar: calendar
                    ) {
                        return nextDate
                    }
                }
            }
            throw PingHandlerError.invalidAlarmData
        default:
            throw PingHandlerError.invalidAlarmData
        }
    }

    /// Produces a stable local-date key used to distinguish repeat occurrences.
    private func occurrenceKey(for date: Date, alarm: [String: Any]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = NativeTransitLocales.deviceTimeZone
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    /// Asks the server to deliver this ping again at the supplied Unix time.
    /// Throws when the request fails or the server returns a non-success status.
    private func reschedule(pingID: String, at date: Date, requireAck: Bool) async throws {
        var request = URLRequest(url: serverBaseURL.appendingPathComponent("reschedule"))
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "ping_id": pingID,
            "scheduled_time": Int(date.timeIntervalSince1970),
            "require_ack": requireAck,
            "expire_on": NSNull(),
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw PingHandlerError.serverRejected((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    /// Marks a ping complete on the server when no further ping is needed.
    private func acknowledge(pingID: String) async throws {
        var request = URLRequest(url: serverBaseURL.appendingPathComponent("ack"))
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ping_id": pingID])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw PingHandlerError.serverRejected((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    // MARK: SQLite and JSON scalar helpers

    /// Binds a Swift string to a SQLite statement parameter.
    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    /// Converts values read from JSONSerialization into an integer when possible.
    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? Int { return value }
        return nil
    }

    /// Converts string or numeric JSON values into a string when possible.
    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// Includes both the Swift error representation and NSError details for
    /// diagnosing framework errors returned to the notification extension.
    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(String(reflecting: error)) [\(nsError.domain):\(nsError.code)] \(nsError.localizedDescription)"
    }

    /// Formats the alarm selected by ping ID as JSON for extension debugging.
    /// Empty strings and dictionaries become null while arrays stay intact.
    private static func alarmDebugJSON(_ alarm: [String: Any]) -> String {
        let normalized = replacingEmptyValues(alarm)
        guard let data = try? JSONSerialization.data(
            withJSONObject: normalized,
            options: [.prettyPrinted, .sortedKeys]
        ), let json = String(data: data, encoding: .utf8) else {
            return "Could not serialize selected alarm"
        }
        return json
    }

    /// Recursively normalizes empty values without dropping array elements.
    private static func replacingEmptyValues(_ value: Any) -> Any {
        if let string = value as? String {
            return string.isEmpty ? NSNull() : string
        }
        if let dictionary = value as? [String: Any] {
            guard !dictionary.isEmpty else { return NSNull() }
            return dictionary.mapValues { replacingEmptyValues($0) }
        }
        if let array = value as? [Any] {
            return array.map { replacingEmptyValues($0) }
        }
        return value
    }
}
