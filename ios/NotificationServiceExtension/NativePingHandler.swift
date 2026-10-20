import Foundation
import SQLite3

private struct OperatorStop {
    let provider: String
    let stopID: String
}

/// How a ping's notification should get the user's attention.
enum PingAlertStyle {
    /// A routine status update: silent, and doesn't light the screen.
    case update
    /// Something the user should know went wrong, such as no estimate: plays
    /// the default sound.
    case problem
    /// A threshold ring: the bundled ring sound, breaking through Focus.
    case ring
}

struct PingResult {
    let title: String
    let body: String
    let debugMessage: String?
    let categoryIdentifier: String?
    let style: PingAlertStyle

    init(
        title: String,
        body: String,
        debugMessage: String? = nil,
        categoryIdentifier: String? = nil,
        style: PingAlertStyle = .update
    ) {
        self.title = title
        self.body = body
        self.debugMessage = debugMessage
        self.categoryIdentifier = categoryIdentifier
        self.style = style
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
    /// The alarm's ping secret, which the server requires to reschedule or
    /// ack its ping. Nil when no saved alarm owns the ping.
    private var pingSecret: String?

    init(appGroupDirectory: URL) {
        self.appGroupDirectory = appGroupDirectory
    }

    /// What a ping has to do, worked out from the saved alarm before acting.
    /// Add a case here, and to [act], for any new kind of ping.
    private enum PingDecision {
        /// No alarm has this ping ID any more.
        case unknownAlarm
        case disabled
        /// Outside the window with nothing under way: wait for its start.
        case beforeWindow(start: Date)
        /// Outside the window with an occurrence under way: end it.
        case windowEnded
        /// A one-off alarm whose occurrence already finished.
        case alreadyFinished
        /// A repeating alarm's next occurrence has started; reset it, then
        /// decide again.
        case startRepeat
        case allThresholdsDone
        case ringing(thresholdIndex: Int)
        case estimate(thresholdIndex: Int)
    }

    /// Processes one server ping. A visible push is the ring itself; the same
    /// server ping ID is rescheduled until the user acknowledges the threshold.
    func handle(pingID: String) async -> PingResult { // todo track the second when ping comes in and decide all schedules to "5-30 sec before the second"
        do {
            var alarms = try loadAlarms()
            let index = alarms.firstIndex { Self.stringValue($0["pingId"]) == pingID }
            pingSecret = index.flatMap { alarms[$0]["pingSecret"] as? String }
            let decision = try decide(alarm: index.map { alarms[$0] }, now: Date())
            return try await act(on: decision, alarms: &alarms, index: index, pingID: pingID)
        } catch {
            return PingResult(title: NativeLocalization.text("native.update_failed.title"), body: NativeLocalization.text("native.update_failed.body"), style: .problem)
        }
    }

    private func decide(alarm: [String: Any]?, now: Date) throws -> PingDecision {
        guard let alarm else { return .unknownAlarm }
        guard (alarm["enabled"] as? Bool) != false else { return .disabled }
        let thresholdStates = Self.sortedThresholds(of: alarm)

        let calendar = NativeTransitLocales.gregorianCalendar()
        if let window = AlarmWindow(alarm: alarm),
           window.activeOccurrence(at: now, calendar: calendar) == nil {
            if Self.occurrenceInProgress(alarm, thresholdStates: thresholdStates) {
                return .windowEnded
            }
            guard let next = window.nextOccurrence(after: now, calendar: calendar) else {
                throw PingHandlerError.invalidAlarmData
            }
            return .beforeWindow(start: next.start)
        }

        if alarm["spent"] as? Bool == true {
            return repeatFrequency(of: alarm) == "none" ? .alreadyFinished : .startRepeat
        }
        guard let active = thresholdStates.firstIndex(where: {
            let outcome = $0["outcome"] as? String
            return outcome == "pending" || outcome == "ringing"
        }) else {
            return .allThresholdsDone
        }
        return thresholdStates[active]["outcome"] as? String == "ringing"
            ? .ringing(thresholdIndex: active)
            : .estimate(thresholdIndex: active)
    }

    private func act(
        on decision: PingDecision,
        alarms: inout [[String: Any]],
        index: Int?,
        pingID: String
    ) async throws -> PingResult {
        guard let index else {
            try? await acknowledge(pingID: pingID)
            return PingResult(title: NativeLocalization.text("native.alarm_no_longer_active.title"), body: NativeLocalization.text("native.alarm_no_longer_active.body"))
        }
        switch decision {
        case .unknownAlarm:
            try? await acknowledge(pingID: pingID)
            return PingResult(title: NativeLocalization.text("native.alarm_no_longer_active.title"), body: NativeLocalization.text("native.alarm_no_longer_active.body"))
        case .disabled:
            try? await acknowledge(pingID: pingID)
            return PingResult(title: NativeLocalization.text("native.alarm_disabled.title"), body: "\(NativeLocalization.text("native.alarm_disabled.body")) \(Self.alarmDebugJSON(alarms[index]))")
        case .beforeWindow(let start):
            try await reschedule(pingID: pingID, at: start, requireAck: false)
            return PingResult(
                title: NativeLocalization.text("native.waiting_for_window.title"),
                body: NativeLocalization.text("native.waiting_for_window.body")
            )
        case .windowEnded:
            return try await concludeOccurrence(
                alarms: &alarms,
                index: index,
                thresholdStates: Self.sortedThresholds(of: alarms[index]),
                pingID: pingID,
                windowEnded: true
            )
        case .alreadyFinished:
            alarms[index]["enabled"] = false
            alarms[index]["pingId"] = NSNull()
            try saveAlarms(alarms)
            try? await acknowledge(pingID: pingID)
            return PingResult(title: NativeLocalization.text("native.alarm_complete.title"), body: NativeLocalization.text("native.alarm_complete.already_finished"))
        case .startRepeat:
            try startRepeat(alarms: &alarms, index: index)
            let next = try decide(alarm: alarms[index], now: Date())
            return try await act(on: next, alarms: &alarms, index: index, pingID: pingID)
        case .allThresholdsDone:
            return try await concludeOccurrence(
                alarms: &alarms,
                index: index,
                thresholdStates: Self.sortedThresholds(of: alarms[index]),
                pingID: pingID,
                windowEnded: false
            )
        case .ringing(let thresholdIndex):
            return try await handleRinging(alarms: &alarms, index: index, thresholdIndex: thresholdIndex, pingID: pingID)
        case .estimate(let thresholdIndex):
            return try await handleEstimate(alarms: &alarms, index: index, thresholdIndex: thresholdIndex, pingID: pingID)
        }
    }

    /// Resets a spent repeating alarm at the start of its next occurrence.
    private func startRepeat(alarms: inout [[String: Any]], index: Int) throws {
        var thresholdStates = Self.sortedThresholds(of: alarms[index])
        for threshold in thresholdStates.indices {
            thresholdStates[threshold]["outcome"] = "pending"
            thresholdStates[threshold]["ringCount"] = 0
        }
        alarms[index]["thresholdStates"] = thresholdStates
        alarms[index]["spent"] = false
        alarms[index]["lastEstimatedMinutesUntilThreshold"] = NSNull()
        alarms[index].removeValue(forKey: "lastEstimatedMinutesUntilArrival")
        try saveAlarms(alarms)
    }

    /// A threshold that's ringing keeps getting the same visible push every
    /// minute until its notification action acknowledges it.
    private func handleRinging(
        alarms: inout [[String: Any]],
        index: Int,
        thresholdIndex: Int,
        pingID: String
    ) async throws -> PingResult {
        let estimate = try await refreshEstimate(alarms: &alarms, index: index, thresholdIndex: thresholdIndex)
        do {
            try await reschedule(pingID: pingID, at: Date().addingTimeInterval(60), requireAck: true)
            try saveAlarms(alarms)
            return ringResult(alarm: alarms[index], thresholdMinutes: estimate.thresholdMinutes)
        } catch {
            return ringResult(alarm: alarms[index], thresholdMinutes: estimate.thresholdMinutes, debugMessage: "Next ping scheduling failed: \(Self.describe(error))")
        }
    }

    /// Updates the arrival estimate for a pending threshold and schedules the
    /// next ping: halfway to the threshold, at it, or ringing now.
    private func handleEstimate(
        alarms: inout [[String: Any]],
        index: Int,
        thresholdIndex: Int,
        pingID: String
    ) async throws -> PingResult {
        let estimate = try await refreshEstimate(alarms: &alarms, index: index, thresholdIndex: thresholdIndex)
        guard let estimateUntilThreshold = estimate.untilThreshold else {
            let retryAt = Date().addingTimeInterval(5 * 60)
            try await reschedule(pingID: pingID, at: retryAt, requireAck: false)
            try saveAlarms(alarms)
            return PingResult(title: NativeLocalization.text("native.estimate_unavailable.title"), body: NativeLocalization.text("native.estimate_unavailable.body"), style: .problem)
        }

        if estimateUntilThreshold > 5 {
            // Recheck halfway through the remaining time to this threshold.
            let delayMinutes = max(1, Int((Double(estimateUntilThreshold) / 2).rounded()))
            try await reschedule(
                pingID: pingID,
                at: Date().addingTimeInterval(TimeInterval(delayMinutes * 60)),
                requireAck: false
            )
            try saveAlarms(alarms)
            return PingResult(
                title: NativeLocalization.text("native.update_scheduled.title"),
                body: NativeLocalization.text("native.update_scheduled.body", values: ["minutes": estimateUntilThreshold, "delay": delayMinutes])
            )
        }

        if estimateUntilThreshold > 0 {
            try await reschedule(
                pingID: pingID,
                at: Date().addingTimeInterval(TimeInterval(estimateUntilThreshold * 60)),
                requireAck: true
            )
            try saveAlarms(alarms)
            return PingResult(title: NativeLocalization.text("native.alarm_approaching.title"), body: NativeLocalization.text("native.alarm_approaching.body", values: ["minutes": estimateUntilThreshold]))
        }

        var thresholdStates = Self.sortedThresholds(of: alarms[index])
        thresholdStates[thresholdIndex]["outcome"] = "ringing"
        let oldCount = Self.intValue(thresholdStates[thresholdIndex]["ringCount"]) ?? 0
        thresholdStates[thresholdIndex]["ringCount"] = oldCount + 1
        alarms[index]["thresholdStates"] = thresholdStates
        try? saveAlarms(alarms)
        do {
            try await reschedule(pingID: pingID, at: Date().addingTimeInterval(60), requireAck: true)
            return ringResult(alarm: alarms[index], thresholdMinutes: estimate.thresholdMinutes)
        } catch {
            return ringResult(alarm: alarms[index], thresholdMinutes: estimate.thresholdMinutes, debugMessage: "Next ping scheduling failed: \(Self.describe(error))")
        }
    }

    /// Fetches a fresh arrival estimate for the given threshold and stores it
    /// on the alarm (unsaved), falling back to the last good value so a
    /// transient API failure doesn't stop the alarm.
    private func refreshEstimate(
        alarms: inout [[String: Any]],
        index: Int,
        thresholdIndex: Int
    ) async throws -> (thresholdMinutes: Int, untilThreshold: Int?) {
        let thresholdStates = Self.sortedThresholds(of: alarms[index])
        alarms[index]["thresholdStates"] = thresholdStates
        guard let thresholdMinutes = Self.intValue(thresholdStates[thresholdIndex]["minutesBeforeArrival"]) else {
            throw PingHandlerError.invalidAlarmData
        }
        let cachedEstimateUntilThreshold = Self.intValue(alarms[index]["lastEstimatedMinutesUntilThreshold"])
            ?? Self.intValue(alarms[index]["lastEstimatedMinutesUntilArrival"]).map { $0 - thresholdMinutes }
        if (alarms[index]["routeApiConfigs"] as? [[String: Any]] ?? []).isEmpty {
            let alarmLocale = NativeTransitLocales.locale(for: alarms[index]["localeCode"] as? String)
            let configs = routeAPIConfigsForLegacyAlarm(alarms[index], locale: alarmLocale)
            if !configs.isEmpty {
                alarms[index]["routeApiConfigs"] = configs
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
            for: alarms[index],
            minimumArrivalMinutes: minimumArrivalMinutes
        )
        let freshEstimateUntilThreshold = freshArrivalEstimate.map { $0 - thresholdMinutes }
        if let freshEstimateUntilThreshold {
            alarms[index]["lastEstimatedMinutesUntilThreshold"] = freshEstimateUntilThreshold
            alarms[index].removeValue(forKey: "lastEstimatedMinutesUntilArrival")
        }
        return (thresholdMinutes, freshEstimateUntilThreshold ?? cachedEstimateUntilThreshold)
    }

    /// Thresholds ordered from the largest minutes-before-arrival down, the
    /// order they ring in.
    private static func sortedThresholds(of alarm: [String: Any]) -> [[String: Any]] {
        (alarm["thresholdStates"] as? [[String: Any]] ?? []).sorted {
            (intValue($0["minutesBeforeArrival"]) ?? 0) > (intValue($1["minutesBeforeArrival"]) ?? 0)
        }
    }

    /// Whether the alarm has started its current occurrence: it has an
    /// estimate, or a threshold has moved on from pending.
    private static func occurrenceInProgress(
        _ alarm: [String: Any],
        thresholdStates: [[String: Any]]
    ) -> Bool {
        alarm["spent"] as? Bool != true && (
            intValue(alarm["lastEstimatedMinutesUntilThreshold"]) != nil ||
                thresholdStates.contains { ($0["outcome"] as? String ?? "pending") != "pending" }
        )
    }

    /// Ends the current occurrence, because its thresholds are done or its
    /// window has ended: schedules the next repeat, or disables a one-off alarm.
    private func concludeOccurrence(
        alarms: inout [[String: Any]],
        index: Int,
        thresholdStates: [[String: Any]],
        pingID: String,
        windowEnded: Bool
    ) async throws -> PingResult {
        var alarm = alarms[index]
        alarm["thresholdStates"] = thresholdStates
        alarm["spent"] = true
        alarm["lastEstimatedMinutesUntilThreshold"] = NSNull()
        alarm.removeValue(forKey: "lastEstimatedMinutesUntilArrival")
        if repeatFrequency(of: alarm) != "none" {
            let nextRepeat = try nextRepeatDate(for: alarm)
            try await reschedule(pingID: pingID, at: nextRepeat, requireAck: false)
            alarms[index] = alarm
            try saveAlarms(alarms)
            return windowEnded
                ? PingResult(title: NativeLocalization.text("native.window_ended.title"), body: NativeLocalization.text("native.window_ended.next_repeat"))
                : PingResult(title: NativeLocalization.text("native.next_repeat.title"), body: NativeLocalization.text("native.next_repeat.body"))
        }
        alarm["enabled"] = false
        alarm["pingId"] = NSNull()
        alarms[index] = alarm
        try saveAlarms(alarms)
        try? await acknowledge(pingID: pingID)
        return windowEnded
            ? PingResult(title: NativeLocalization.text("native.window_ended.title"), body: NativeLocalization.text("native.window_ended.no_repeat"))
            : PingResult(title: NativeLocalization.text("native.alarm_complete.title"), body: NativeLocalization.text("native.alarm_complete.thresholds_done"))
    }

    private func ringResult(alarm: [String: Any], thresholdMinutes: Int, debugMessage: String? = nil) -> PingResult {
        let routeConfigs = alarm["routeApiConfigs"] as? [[String: Any]] ?? []
        let transportMode = routeConfigs.first?["mode"] as? String ?? NativeLocalization.busMode
        let modeValues: [String: Any] = [
            "transportMode": NativeLocalization.transportMode(transportMode),
            "transportModeTitle": NativeLocalization.transportMode(transportMode, titleCase: true)
        ]
        let title = (alarm["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? NativeLocalization.text("native.ring.title", values: modeValues)
        var bodyValues = modeValues
        bodyValues["minutes"] = thresholdMinutes
        return PingResult(
            title: title,
            body: NativeLocalization.text("native.ring.body", values: bodyValues),
            debugMessage: debugMessage,
            categoryIdentifier: "transport_alarm_ring",
            style: .ring
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
        let routeNumbers = Self.routeNumbers(of: alarm)
        guard let stopID = alarm["gtfsStopId"] as? String, !routeNumbers.isEmpty else {
            return nil
        }

        let locale = NativeTransitLocales.locale(for: alarm["localeCode"] as? String)
        var hkRequests: [NativeTransitETARequest] = []
        var liveDates: [Date] = []
        // Trips a live feed shows as running or already past the stop, so the
        // timetable fallback doesn't offer a bus that has gone.
        var liveTripIDs: Set<String> = []
        for source in LiveSource.sources(for: alarm, locale: locale) {
            switch source {
            case .hkOperatorJSON(let request):
                hkRequests.append(request)
            case .gbLive:
                let result = await GBLiveArrivals(
                    databaseURL: locale.databaseURL(in: appGroupDirectory),
                    stopID: stopID,
                    routes: Self.routeDestinations(of: alarm),
                    timeZone: locale.timeZone
                ).fetch()
                liveDates += result.arrivals
                liveTripIDs.formUnion(result.liveTripIDs)
            case .unsupported:
                break
            }
        }

        if !hkRequests.isEmpty {
            liveDates += await fetchLiveETAs(from: hkRequests, allowedRoutes: Set(routeNumbers))
        }
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
        // Each locale's timetable comes from its own GTFS database; add a case
        // for a locale whose timetable needs a different query.
        switch locale.code {
        case "hk", "gb":
            return scheduledMinutesUntilArrival(
                stopID: stopID,
                routeNumbers: routeNumbers,
                locale: locale,
                minimumArrivalMinutes: minimumArrivalMinutes,
                excludingTrips: liveTripIDs
            )
        default:
            return nil
        }
    }

    /// Migrates older alarm records once by saving the provider URL for each
    /// selected route. New alarms already contain these values at creation.
    private func routeAPIConfigsForLegacyAlarm(
        _ alarm: [String: Any],
        locale: NativeTransitLocale
    ) -> [[String: Any]] {
        let routeNumbers = Self.routeNumbers(of: alarm)
        guard let stopID = alarm["gtfsStopId"] as? String else {
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
        let databaseURL = locale.databaseURL(in: appGroupDirectory)
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
        minimumArrivalMinutes: Int?,
        excludingTrips: Set<String> = []
    ) -> Int? {
        guard !routeNumbers.isEmpty else { return nil }
        let databaseURL = locale.databaseURL(in: appGroupDirectory)
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
            SELECT st.arrival_time, st.trip_id
            FROM gtfs_stop_times st
            INNER JOIN gtfs_trips t ON st.trip_id = t.trip_id
            INNER JOIN gtfs_routes r ON t.route_id = r.route_id
            WHERE st.stop_id = ? AND r.route_short_name IN (\(placeholders))
              AND st.arrival_time > ?
              -- Runs today by its weekly calendar or an added date, and isn't
              -- removed for today in calendar_dates.
              AND (
                EXISTS (
                  SELECT 1 FROM gtfs_calendar c
                  WHERE c.service_id = t.service_id AND c.\(weekdayColumn) = 1
                    AND c.start_date <= ? AND c.end_date >= ?
                )
                OR EXISTS (
                  SELECT 1 FROM gtfs_calendar_dates added
                  WHERE added.service_id = t.service_id
                    AND added.date = ? AND added.exception_type = 1
                )
              )
              AND NOT EXISTS (
                SELECT 1 FROM gtfs_calendar_dates removed
                WHERE removed.service_id = t.service_id
                  AND removed.date = ? AND removed.exception_type = 2
              )
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
        for offset in Int32(1)...Int32(4) {
            bind(dateString, to: statement, at: timeBinding + offset)
        }

        let startOfDay = calendar.startOfDay(for: now)
        var soonest: Int?
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let timePointer = sqlite3_column_text(statement, 0) else { continue }
            if let tripPointer = sqlite3_column_text(statement, 1),
               excludingTrips.contains(String(cString: tripPointer)) { continue }
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

    /// The start of the alarm's next occurrence after now, from its window
    /// and repeat days in the device's timezone.
    private func nextRepeatDate(for alarm: [String: Any]) throws -> Date {
        guard let window = AlarmWindow(alarm: alarm),
              let next = window.nextOccurrence(
                  after: Date(),
                  calendar: NativeTransitLocales.gregorianCalendar()
              ) else {
            throw PingHandlerError.invalidAlarmData
        }
        return next.start
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
        guard let pingSecret else { throw PingHandlerError.serverRejected(403) }
        var request = URLRequest(url: serverBaseURL.appendingPathComponent("reschedule"))
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "ping_id": pingID,
            "ping_secret": pingSecret,
            // A delay rather than a time, so the server uses its own clock.
            "delay_seconds": max(0, Int(date.timeIntervalSinceNow.rounded())),
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
        // Without the secret the server would refuse; the ping expires on its own.
        guard let pingSecret else { return }
        var request = URLRequest(url: serverBaseURL.appendingPathComponent("ack"))
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ping_id": pingID, "ping_secret": pingSecret])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw PingHandlerError.serverRejected((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    // MARK: SQLite and JSON scalar helpers

    /// Each selected route's saved destination (English name), or nil when
    /// the alarm saved none, for matching live buses.
    static func routeDestinations(of alarm: [String: Any]) -> [String: String?] {
        var destinations: [String: String?] = [:]
        if let routes = alarm["routeNumbers"] as? [String: Any] {
            for (route, value) in routes {
                destinations[route] = (value as? [String: Any])?["en"] as? String
            }
        } else {
            for route in routeNumbers(of: alarm) { destinations[route] = .some(nil) }
        }
        return destinations
    }

    /// The route numbers selected on an alarm. Alarms now save a map of route
    /// number to its destination names; older ones saved a plain list.
    static func routeNumbers(of alarm: [String: Any]) -> [String] {
        if let routes = alarm["routeNumbers"] as? [String: Any] {
            return routes.keys.sorted()
        }
        return alarm["routeNumbers"] as? [String] ?? []
    }

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
