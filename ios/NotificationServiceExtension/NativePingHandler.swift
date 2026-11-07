import Foundation
import SQLite3

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
    let categoryIdentifier: String?
    let style: PingAlertStyle

    init(
        title: String,
        body: String,
        categoryIdentifier: String? = nil,
        style: PingAlertStyle = .update
    ) {
        self.title = title
        self.body = body
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
    /// The ID of the alarm that owns the ping, for its watchdog notification.
    private var alarmID: String?
    /// When the ping arrived, for the live fetch's deadline.
    private let receivedAt = Date()
    /// How long after the ping arrives the arrival lookup may run, leaving
    /// the rest of the extension's 24 seconds to reschedule and save.
    private static let estimateBudget: TimeInterval = 14
    /// Set when the arrival lookup ran out of time, so the notice can say so.
    private var estimateTimedOut = false

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
    func handle(pingID: String) async -> PingResult {
        PingTiming.recordArrival(at: Date())
        do {
            var alarms = try loadAlarms()
            let index = alarms.firstIndex { Self.stringValue($0["pingId"]) == pingID }
            // A ping the app couldn't cancel, from an alarm since turned off,
            // changed or deleted, still has its secret in the orphan list.
            pingSecret = index.flatMap { alarms[$0]["pingSecret"] as? String }
                ?? (index == nil ? orphanedPings()[pingID] : nil)
            alarmID = index.flatMap { Self.stringValue(alarms[$0]["id"]) }
            let decision = try decide(alarm: index.map { alarms[$0] }, now: Date())
            let result = try await act(on: decision, alarms: &alarms, index: index, pingID: pingID)
            guard estimateTimedOut, result.style == .update else { return result }
            // A lookup that ran out of time counts as a failed fetch: say so,
            // with a sound, alongside what this ping went on to do.
            return PingResult(
                title: NativeLocalization.text("native.estimate_slow.title"),
                body: "\(NativeLocalization.text("native.estimate_slow.body")) \(result.body)",
                categoryIdentifier: result.categoryIdentifier,
                style: .problem
            )
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
            return .beforeWindow(start: next.activeFrom)
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
            // Acknowledged once, so the server stops resending it.
            if pingSecret != nil, (try? await acknowledge(pingID: pingID)) != nil {
                removeOrphanedPing(pingID)
            }
            return PingResult(title: NativeLocalization.text("native.alarm_no_longer_active.title"), body: NativeLocalization.text("native.alarm_no_longer_active.body"))
        }
        switch decision {
        case .unknownAlarm:
            try? await acknowledge(pingID: pingID)
            return PingResult(title: NativeLocalization.text("native.alarm_no_longer_active.title"), body: NativeLocalization.text("native.alarm_no_longer_active.body"))
        case .disabled:
            try? await acknowledge(pingID: pingID)
            return PingResult(title: NativeLocalization.text("native.alarm_disabled.title"), body: NativeLocalization.text("native.alarm_disabled.body"))
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
        Self.clearOccurrenceProgress(&alarms[index])
        try saveAlarms(alarms)
    }

    /// A threshold that's ringing keeps getting the same visible push every
    /// minute until its notification action acknowledges it, it has rung
    /// maxRingsPerThreshold times, or the next threshold is due.
    private func handleRinging(
        alarms: inout [[String: Any]],
        index: Int,
        thresholdIndex: Int,
        pingID: String
    ) async throws -> PingResult {
        let estimate = try await refreshEstimate(alarms: &alarms, index: index, thresholdIndex: thresholdIndex)
        var thresholdStates = Self.sortedThresholds(of: alarms[index])
        let ringCount = Self.intValue(thresholdStates[thresholdIndex]["ringCount"]) ?? 0
        let maxRings = Self.intValue(alarms[index]["maxRingsPerThreshold"]) ?? 10
        let nextIndex = thresholdStates.indices.first {
            $0 > thresholdIndex && (thresholdStates[$0]["outcome"] as? String ?? "pending") == "pending"
        }
        // Minutes until the next threshold, from this threshold's estimate.
        let untilNext: Int? = nextIndex.flatMap { next in
            guard let untilThreshold = estimate.untilThreshold,
                  let nextMinutes = Self.intValue(thresholdStates[next]["minutesBeforeArrival"]) else { return nil }
            return untilThreshold + estimate.thresholdMinutes - nextMinutes
        }
        let nextDue = untilNext.map { $0 <= 0 } ?? false

        if nextDue || ringCount >= maxRings {
            // Stop ringing this threshold and decide again, so this ping moves
            // on to the next threshold (ringing it now if it's due) or ends
            // the occurrence.
            thresholdStates[thresholdIndex]["outcome"] = nextDue ? "superseded" : "missed"
            alarms[index]["thresholdStates"] = thresholdStates
            if let untilNext {
                alarms[index]["lastEstimatedMinutesUntilThreshold"] = untilNext
            } else if nextIndex != nil {
                alarms[index]["lastEstimatedMinutesUntilThreshold"] = NSNull()
            }
            try saveAlarms(alarms)
            let next = try decide(alarm: alarms[index], now: Date())
            return try await act(on: next, alarms: &alarms, index: index, pingID: pingID)
        }

        thresholdStates[thresholdIndex]["ringCount"] = ringCount + 1
        alarms[index]["thresholdStates"] = thresholdStates
        do {
            try await reschedule(pingID: pingID, at: Self.ringTime(Date().addingTimeInterval(60)), requireAck: true)
            try saveAlarms(alarms)
        } catch {
            // Still ring; the server's fallback resend brings the next ping.
        }
        return ringResult(alarm: alarms[index], thresholdMinutes: estimate.thresholdMinutes)
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
        switch estimate.outcome {
        case .tooLate, .noBus(windowPassed: true):
            // A bus too close for every threshold rings nothing, and no bus
            // by the window's end won't come: either way the occurrence ends.
            return try await concludeOccurrence(
                alarms: &alarms,
                index: index,
                thresholdStates: Self.sortedThresholds(of: alarms[index]),
                pingID: pingID,
                windowEnded: true
            )
        default:
            break
        }
        if estimate.activeIndex != thresholdIndex {
            // Thresholds already past when the bus was picked were skipped:
            // decide again for the next one.
            try saveAlarms(alarms)
            let next = try decide(alarm: alarms[index], now: Date())
            return try await act(on: next, alarms: &alarms, index: index, pingID: pingID)
        }
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
                at: Self.ringTime(Date().addingTimeInterval(TimeInterval(estimateUntilThreshold * 60))),
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
        // Still ring if this fails; the server's fallback resend brings the
        // next ping.
        try? await reschedule(pingID: pingID, at: Self.ringTime(Date().addingTimeInterval(60)), requireAck: true)
        return ringResult(alarm: alarms[index], thresholdMinutes: estimate.thresholdMinutes)
    }

    /// What a ping found when choosing its bus.
    private enum LockOutcome {
        /// The lookup timed out with no bus chosen before.
        case unavailable
        /// No bus is arriving within the window; [windowPassed] once its end
        /// has passed, when none will.
        case noBus(windowPassed: Bool)
        /// The bus first picked is too close for every threshold.
        case tooLate
        case locked(LockedArrival, stale: Bool)
    }

    private struct Estimate {
        let thresholdMinutes: Int
        /// Minutes from now until the active threshold, or nil without a bus.
        let untilThreshold: Int?
        let outcome: LockOutcome
        /// The threshold to aim at, which moves on when thresholds already
        /// past are skipped as a bus is first picked.
        let activeIndex: Int
    }

    /// Chooses the bus to aim at this ping (see ArrivalLock.decide) and
    /// stores it on the alarm, unsaved, with the minutes left until the
    /// given threshold.
    private func refreshEstimate(
        alarms: inout [[String: Any]],
        index: Int,
        thresholdIndex: Int
    ) async throws -> Estimate {
        let thresholdStates = Self.sortedThresholds(of: alarms[index])
        alarms[index]["thresholdStates"] = thresholdStates
        guard let thresholdMinutes = Self.intValue(thresholdStates[thresholdIndex]["minutesBeforeArrival"]) else {
            throw PingHandlerError.invalidAlarmData
        }
        let outcome = await updateLock(alarms: &alarms, index: index)
        let states = Self.sortedThresholds(of: alarms[index])
        let activeIndex = states.firstIndex {
            let outcome = $0["outcome"] as? String
            return outcome == "pending" || outcome == "ringing"
        } ?? thresholdIndex
        guard case .locked(let locked, _) = outcome else {
            return Estimate(thresholdMinutes: thresholdMinutes, untilThreshold: nil, outcome: outcome, activeIndex: activeIndex)
        }
        let untilThreshold = Int(locked.arrival.timeIntervalSinceNow / 60) - thresholdMinutes
        alarms[index]["lastEstimatedMinutesUntilThreshold"] = untilThreshold
        return Estimate(thresholdMinutes: thresholdMinutes, untilThreshold: untilThreshold, outcome: outcome, activeIndex: activeIndex)
    }

    /// Looks up this ping's buses, decides which to follow, and saves it on
    /// the alarm, unsaved. When a bus is first picked, thresholds already
    /// past are marked missed.
    private func updateLock(alarms: inout [[String: Any]], index: Int) async -> LockOutcome {
        let alarm = alarms[index]
        let now = Date()
        guard let window = AlarmWindow(alarm: alarm),
              let occurrence = window.activeOccurrence(at: now, calendar: NativeTransitLocales.gregorianCalendar()) else {
            return .noBus(windowPassed: true)
        }
        let current = LockedArrival(json: alarm["lockedArrival"])
        let thresholdStates = Self.sortedThresholds(of: alarm)
        let fresh = current == nil &&
            thresholdStates.allSatisfy { ($0["outcome"] as? String ?? "pending") == "pending" }
        let candidates = await candidatesWithinBudget(for: alarm)
        if candidates == nil && current == nil { return .unavailable }
        let decision = ArrivalLock.decide(
            candidates: candidates ?? [],
            windowStart: occurrence.boardFrom,
            windowEnd: occurrence.boardUntil,
            now: now,
            current: current,
            skipped: Set(alarm["skippedArrivals"] as? [String] ?? []),
            liveOnly: alarm["liveOnly"] as? Bool == true,
            stableIDs: Self.followsOneBus(alarm),
            onlyAfter: (alarm["nextBusAfterEpochSeconds"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue)
            }
        )
        guard let locked = decision.locked else {
            alarms[index]["lockedArrival"] = NSNull()
            return .noBus(windowPassed: now >= occurrence.boardUntil)
        }
        alarms[index]["lockedArrival"] = locked.json
        // Once "Next bus" has found its bus, later picks are unrestricted.
        if decision.changedBus { alarms[index]["nextBusAfterEpochSeconds"] = NSNull() }
        if fresh {
            let minutes = thresholdStates.map { Self.intValue($0["minutesBeforeArrival"]) ?? 0 }
            let ahead = ArrivalLock.thresholdsStillAhead(minutes, arrival: locked.arrival, now: now)
            guard let firstAhead = ahead.first else { return .tooLate }
            if firstAhead > 0 {
                var states = thresholdStates
                for skipped in 0..<firstAhead { states[skipped]["outcome"] = "missed" }
                alarms[index]["thresholdStates"] = states
            }
        }
        return .locked(locked, stale: decision.stale)
    }

    /// Whether every route of the alarm can follow one bus: BODS and TfL
    /// identify buses, the HK operators don't. The app's canFollowOneBus.
    private static func followsOneBus(_ alarm: [String: Any]) -> Bool {
        let configs = alarm["routeApiConfigs"] as? [[String: Any]] ?? []
        if configs.isEmpty { return (alarm["localeCode"] as? String) == "gb" }
        return configs.allSatisfy { ($0["providerCode"] as? String) == "bods" }
    }

    /// Runs [arrivalCandidates] until [estimateBudget] after the ping
    /// arrived. Past that, the lookup is cancelled and this returns nil, as
    /// for a failed fetch, so the ping still has time to reschedule.
    private func candidatesWithinBudget(for alarm: [String: Any]) async -> [ArrivalCandidate]? {
        let remaining = Self.estimateBudget - Date().timeIntervalSince(receivedAt)
        guard remaining > 0 else {
            estimateTimedOut = true
            return nil
        }
        let outcome: [ArrivalCandidate]?? = await withTaskGroup(of: [ArrivalCandidate]??.self) { group in
            group.addTask {
                .some(await self.arrivalCandidates(for: alarm))
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                return .none
            }
            let first = await group.next() ?? .none
            group.cancelAll()
            return first
        }
        guard let outcome else {
            estimateTimedOut = true
            return nil
        }
        return outcome
    }

    /// Thresholds ordered from the largest minutes-before-arrival down, the
    /// order they ring in.
    private static func sortedThresholds(of alarm: [String: Any]) -> [[String: Any]] {
        (alarm["thresholdStates"] as? [[String: Any]] ?? []).sorted {
            (intValue($0["minutesBeforeArrival"]) ?? 0) > (intValue($1["minutesBeforeArrival"]) ?? 0)
        }
    }

    /// Whether the alarm has started its current occurrence: it's following
    /// a bus, has an estimate, or a threshold has moved on from pending.
    private static func occurrenceInProgress(
        _ alarm: [String: Any],
        thresholdStates: [[String: Any]]
    ) -> Bool {
        alarm["spent"] as? Bool != true && (
            LockedArrival(json: alarm["lockedArrival"]) != nil ||
                intValue(alarm["lastEstimatedMinutesUntilThreshold"]) != nil ||
                thresholdStates.contains { ($0["outcome"] as? String ?? "pending") != "pending" }
        )
    }

    /// Clears what an occurrence chose, for the next one.
    private static func clearOccurrenceProgress(_ alarm: inout [String: Any]) {
        alarm["lastEstimatedMinutesUntilThreshold"] = NSNull()
        alarm["lockedArrival"] = NSNull()
        alarm["skippedArrivals"] = [String]()
        alarm["nextBusAfterEpochSeconds"] = NSNull()
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
        Self.clearOccurrenceProgress(&alarm)
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

    private func ringResult(alarm: [String: Any], thresholdMinutes: Int) -> PingResult {
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
            categoryIdentifier: "transport_alarm_ring",
            style: .ring
        )
    }

    // MARK: Shared alarm data

    /// The alarms JSON file in the shared App Group container.
    private var alarmsFile: URL {
        appGroupDirectory.appendingPathComponent("alarms.json")
    }

    /// Reads the serialized alarm list used by both the app and extension.
    private func loadAlarms() throws -> [[String: Any]] {
        let data = try Data(contentsOf: alarmsFile, options: [.mappedIfSafe])
        guard let alarms = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PingHandlerError.invalidAlarmData
        }
        // Saved before windows meant boarding times; stored converted on the
        // next save.
        return alarms.map(AlarmWindow.migrated)
    }

    /// Atomically writes the updated alarm list so an interrupted write does not
    /// leave partially serialized state for the app or a later extension run.
    private func saveAlarms(_ alarms: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: alarms, options: [.sortedKeys])
        try data.write(to: alarmsFile, options: [.atomic])
    }

    /// Pings the app couldn't cancel, as ping ID to secret (written by the
    /// app's OrphanedPingStore).
    private var orphanedPingsFile: URL {
        appGroupDirectory.appendingPathComponent("orphaned_pings.json")
    }

    private func orphanedPings() -> [String: String] {
        guard let data = try? Data(contentsOf: orphanedPingsFile),
              let pings = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return pings
    }

    private func removeOrphanedPing(_ pingID: String) {
        var pings = orphanedPings()
        guard pings.removeValue(forKey: pingID) != nil,
              let data = try? JSONSerialization.data(withJSONObject: pings) else { return }
        try? data.write(to: orphanedPingsFile, options: [.atomic])
    }

    /// Reads the repeat mode, treating a missing repeat configuration as one-shot.
    private func repeatFrequency(of alarm: [String: Any]) -> String {
        let repeatInfo = alarm["repeat"] as? [String: Any]
        return repeatInfo?["frequency"] as? String ?? "none"
    }

    // MARK: Arrival estimate (GTFS SQLite plus provider APIs)

    /// Every bus on the alarm's routes this ping could aim at: live ones
    /// from the registered operators, then timetabled ones not already
    /// tracked live. Whether the alarm is live only is left to the lock.
    private func arrivalCandidates(for alarm: [String: Any]) async -> [ArrivalCandidate] {
        let routeNumbers = Self.routeNumbers(of: alarm)
        guard let stopID = alarm["gtfsStopId"] as? String, !routeNumbers.isEmpty else {
            return []
        }

        let locale = NativeTransitLocales.locale(for: alarm["localeCode"] as? String)
        var hkRequests: [NativeTransitETARequest] = []
        var candidates: [ArrivalCandidate] = []
        // Trips a live feed shows as running or already past the stop, so the
        // timetable doesn't offer a bus that has gone.
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
                candidates += result.arrivals
                liveTripIDs.formUnion(result.liveTripIDs)
            case .unsupported:
                break
            }
        }

        if !hkRequests.isEmpty {
            candidates += await fetchLiveETAs(from: hkRequests, allowedRoutes: Set(routeNumbers))
        }
        // Each locale's timetable comes from its own GTFS database; add a case
        // for a locale whose timetable needs a different query.
        switch locale.code {
        case "hk", "gb":
            candidates += scheduledCandidates(
                stopID: stopID,
                routeNumbers: routeNumbers,
                locale: locale,
                excludingTrips: liveTripIDs
            )
        default:
            break
        }
        return candidates
    }

    /// The timetabled arrivals of the selected routes at the stop, from the
    /// locale's GTFS calendar. Searches today's service day and yesterday's,
    /// whose trips after midnight carry times past 24:00.
    private func scheduledCandidates(
        stopID: String,
        routeNumbers: [String],
        locale: NativeTransitLocale,
        excludingTrips: Set<String> = []
    ) -> [ArrivalCandidate] {
        guard !routeNumbers.isEmpty,
              let database = GBLiveArrivals.openDatabase(locale.databaseURL(in: appGroupDirectory)) else { return [] }
        defer { sqlite3_close(database) }

        let calendar = locale.gregorianCalendar
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let secondsIntoToday = Int(now.timeIntervalSince(today))
        var candidates: [ArrivalCandidate] = []
        for dayOffset in [0, -1] {
            guard let serviceDay = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            // GTFS times count from the service day's start, so on yesterday's
            // service day now is 24 hours later.
            let after = secondsIntoToday - dayOffset * 86400
            candidates += scheduledArrivals(
                database: database,
                stopID: stopID,
                routeNumbers: routeNumbers,
                serviceDay: serviceDay,
                afterSeconds: after,
                calendar: calendar,
                excludingTrips: excludingTrips
            )
        }
        return candidates
    }

    /// The selected routes' departures after [afterSeconds] on one GTFS
    /// service day.
    private func scheduledArrivals(
        database: OpaquePointer,
        stopID: String,
        routeNumbers: [String],
        serviceDay: Date,
        afterSeconds: Int,
        calendar: Calendar,
        excludingTrips: Set<String>
    ) -> [ArrivalCandidate] {
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: serviceDay)
        guard let year = components.year, let month = components.month,
              let day = components.day, let weekday = components.weekday else { return [] }
        let weekdayColumns = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let weekdayColumn = weekdayColumns[weekday - 1]
        let dateString = String(format: "%04d%02d%02d", year, month, day)
        let afterTime = String(format: "%02d:%02d:%02d", afterSeconds / 3600, (afterSeconds % 3600) / 60, afterSeconds % 60)
        let placeholders = Array(repeating: "?", count: routeNumbers.count).joined(separator: ",")
        let sql = """
            SELECT st.arrival_time, st.trip_id, r.route_short_name
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
        let bindings = [stopID] + routeNumbers + [afterTime, dateString, dateString, dateString, dateString]
        var arrivals: [ArrivalCandidate] = []
        GBLiveArrivals.query(database, sql, bindings) { row in
            let tripID = GBLiveArrivals.text(row, 1)
            if let tripID, excludingTrips.contains(tripID) { return }
            guard let seconds = GBLiveArrivals.gtfsSeconds(GBLiveArrivals.text(row, 0)),
                  let route = GBLiveArrivals.text(row, 2) else { return }
            arrivals.append(ArrivalCandidate(
                arrival: serviceDay.addingTimeInterval(TimeInterval(seconds)),
                isLive: false,
                routeNumber: route,
                tripID: tripID,
                vehicleID: nil
            ))
        }
        return arrivals
    }

    /// Fetches at most 24 operator/route endpoints, keeping no more than six
    /// network requests active at once to bound extension work and memory use.
    private func fetchLiveETAs(from requests: [NativeTransitETARequest], allowedRoutes: Set<String>) async -> [ArrivalCandidate] {
        await withTaskGroup(of: [ArrivalCandidate].self, returning: [ArrivalCandidate].self) { group in
            var iterator = requests.prefix(24).makeIterator()
            for _ in 0..<min(6, requests.count) {
                if let request = iterator.next() {
                    group.addTask { await Self.fetchLiveETA(request: request, allowedRoutes: allowedRoutes) }
                }
            }

            var arrivals: [ArrivalCandidate] = []
            while let result = await group.next() {
                arrivals.append(contentsOf: result)
                if let request = iterator.next() {
                    group.addTask { await Self.fetchLiveETA(request: request, allowedRoutes: allowedRoutes) }
                }
            }
            return arrivals
        }
    }

    /// Performs one API request and delegates its response decoding to the
    /// matching operator provider. Failed or non-200 responses produce no
    /// ETAs. The HK operators' ETAs carry no ID for their bus.
    private static func fetchLiveETA(request: NativeTransitETARequest, allowedRoutes: Set<String>) async -> [ArrivalCandidate] {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.timeoutInterval = 3
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            return NativeTransitETAProviders.arrivals(
                from: data,
                providerCode: request.providerCode,
                matching: allowedRoutes
            ).map {
                ArrivalCandidate(arrival: $0.date, isLive: true, routeNumber: $0.route, tripID: nil, vehicleID: nil)
            }
        } catch {
            return []
        }
    }

    // MARK: Alarm schedule and server ping

    /// When the alarm's next occurrence becomes active, from its window and
    /// repeat days in the device's timezone.
    private func nextRepeatDate(for alarm: [String: Any]) throws -> Date {
        guard let window = AlarmWindow(alarm: alarm),
              let next = window.nextOccurrence(
                  after: Date(),
                  calendar: NativeTransitLocales.gregorianCalendar()
              ) else {
            throw PingHandlerError.invalidAlarmData
        }
        return next.activeFrom
    }

    /// When to schedule a ping that should ring at [target], so it arrives
    /// a few seconds before it rather than up to a minute after.
    private static func ringTime(_ target: Date) -> Date {
        Date().addingTimeInterval(PingTiming.delay(toArriveBy: target))
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
        if let alarmID { await PingWatchdog.arm(alarmID: alarmID, nextPingAt: date) }
    }

    /// Marks a ping complete on the server when no further ping is needed.
    private func acknowledge(pingID: String) async throws {
        // No more pings are coming, whether or not the server hears this.
        if let alarmID { PingWatchdog.disarm(alarmID: alarmID) }
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
        for (route, value) in alarm["routeNumbers"] as? [String: Any] ?? [:] {
            destinations[route] = (value as? [String: Any])?["en"] as? String
        }
        return destinations
    }

    /// The route numbers selected on an alarm, saved as a map of route number
    /// to its destination names.
    static func routeNumbers(of alarm: [String: Any]) -> [String] {
        (alarm["routeNumbers"] as? [String: Any])?.keys.sorted() ?? []
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
}
