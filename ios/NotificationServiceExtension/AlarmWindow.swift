import Foundation

/// An alarm's boarding window and repeat days, read from alarms.json: the
/// range of arrivals the user wants to board. Times are wall-clock minutes in
/// the device's timezone, as the app saves them; a window whose end is
/// earlier than its start crosses midnight. Mirrors the app's
/// boarding_window.dart.
struct AlarmWindow {
    /// How long after the window ends a delayed bus is still followed.
    static let grace: TimeInterval = 30 * 60
    static let defaultLeadMinutes = 10

    let startMinutes: Int
    let endMinutes: Int
    let frequency: String
    /// Dart weekday numbers: Monday is 1, Sunday is 7.
    let weekdays: Set<Int>
    let daysOfMonth: Set<Int>
    /// The largest threshold, and how long before the earliest ring checks
    /// start: together, how long before the window an occurrence is active.
    let largestThresholdMinutes: Int
    let leadMinutes: Int

    init?(alarm: [String: Any]) {
        guard let start = (alarm["windowStart"] as? NSNumber)?.intValue,
              let end = (alarm["windowEnd"] as? NSNumber)?.intValue else {
            return nil
        }
        let repeatInfo = alarm["repeat"] as? [String: Any] ?? [:]
        startMinutes = start
        endMinutes = end
        frequency = repeatInfo["frequency"] as? String ?? "none"
        weekdays = Set((repeatInfo["weekdays"] as? [NSNumber] ?? []).map(\.intValue))
        daysOfMonth = Set((repeatInfo["dayOfMonth"] as? [NSNumber] ?? []).map(\.intValue))
        largestThresholdMinutes = Self.largestThreshold(of: alarm)
        leadMinutes = (alarm["checkLeadMinutes"] as? NSNumber)?.intValue ?? Self.defaultLeadMinutes
    }

    static func largestThreshold(of alarm: [String: Any]) -> Int {
        (alarm["thresholdStates"] as? [[String: Any]] ?? [])
            .compactMap { ($0["minutesBeforeArrival"] as? NSNumber)?.intValue }
            .max() ?? 0
    }

    /// Whether an occurrence's boarding window starts on the day containing
    /// [day]. One-off alarms ("none") can run on any day.
    func repeats(on day: Date, calendar: Calendar) -> Bool {
        switch frequency {
        case "none", "daily":
            return true
        case "weekly":
            let weekday = calendar.component(.weekday, from: day)
            return weekdays.contains(weekday == 1 ? 7 : weekday - 1)
        case "monthly":
            return daysOfMonth.contains(calendar.component(.day, from: day))
        default:
            return false
        }
    }

    /// The occurrence whose boarding window starts on the day containing
    /// [day]: active from the lead time before the earliest ring until
    /// [grace] after the window ends.
    func occurrence(boardingOn day: Date, calendar: Calendar) -> BoardingOccurrence? {
        let dayStart = calendar.startOfDay(for: day)
        guard let boardFrom = NativeTransitLocales.date(
            minutesAfterMidnight: startMinutes,
            on: dayStart,
            calendar: calendar
        ) else { return nil }
        let endDay = endMinutes < startMinutes
            ? calendar.date(byAdding: .day, value: 1, to: dayStart)
            : dayStart
        guard let endDay,
              let boardUntil = NativeTransitLocales.date(
                  minutesAfterMidnight: endMinutes,
                  on: endDay,
                  calendar: calendar
              ),
              boardUntil >= boardFrom else { return nil }
        let leadSeconds = TimeInterval((largestThresholdMinutes + leadMinutes) * 60)
        return BoardingOccurrence(
            boardFrom: boardFrom,
            boardUntil: boardUntil,
            activeFrom: boardFrom.addingTimeInterval(-leadSeconds),
            activeUntil: boardUntil.addingTimeInterval(Self.grace)
        )
    }

    /// The occurrence active at [now], if any. It belongs to the day its
    /// boarding window starts, even when it becomes active the evening before.
    func activeOccurrence(at now: Date, calendar: Calendar) -> BoardingOccurrence? {
        for offset in [-1, 0, 1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  repeats(on: day, calendar: calendar),
                  let occurrence = occurrence(boardingOn: day, calendar: calendar),
                  occurrence.activeFrom <= now, now < occurrence.activeUntil else { continue }
            return occurrence
        }
        return nil
    }

    /// The first occurrence that becomes active after [now], within roughly
    /// a year.
    func nextOccurrence(after now: Date, calendar: Calendar) -> BoardingOccurrence? {
        for offset in -1...370 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  repeats(on: day, calendar: calendar),
                  let occurrence = occurrence(boardingOn: day, calendar: calendar),
                  occurrence.activeFrom > now else { continue }
            return occurrence
        }
        return nil
    }

    /// Converts an alarm saved before its window meant boarding times, as
    /// the app's TransportAlarm.fromJson does, so whichever reads it first
    /// agrees: the window starts the largest threshold later and keeps its
    /// end (30 minutes long if too short), its progress is replanned, and
    /// it's marked for the user to check.
    static func migrated(_ alarm: [String: Any]) -> [String: Any] {
        guard ((alarm["windowVersion"] as? NSNumber)?.intValue ?? 1) < 2,
              let start = (alarm["windowStart"] as? NSNumber)?.intValue,
              let end = (alarm["windowEnd"] as? NSNumber)?.intValue else { return alarm }
        let day = 24 * 60
        let largest = largestThreshold(of: alarm)
        let length = ((end - start) % day + day) % day
        let newStart = (start + largest) % day
        var converted = alarm
        converted["windowStart"] = newStart
        converted["windowEnd"] = largest >= length ? (newStart + 30) % day : end
        converted["windowVersion"] = 2
        converted["needsReview"] = true
        converted["lockedArrival"] = NSNull()
        converted["skippedArrivals"] = [String]()
        converted["nextBusAfterEpochSeconds"] = NSNull()
        return converted
    }
}

/// One occurrence of an alarm, as real times: the boarding window, and when
/// the alarm is checking for it.
struct BoardingOccurrence {
    let boardFrom: Date
    let boardUntil: Date
    let activeFrom: Date
    let activeUntil: Date
}

// MARK: Following one bus (mirrors the app's arrival_lock.dart)

/// One bus an alarm could aim at.
struct ArrivalCandidate {
    let arrival: Date
    let isLive: Bool
    let routeNumber: String
    /// The GTFS trip, from the timetable or a feed that matches vehicles to
    /// trips (BODS).
    let tripID: String?
    /// The feed's own vehicle ID, where it has one (TfL).
    let vehicleID: String?

    var identity: String? {
        if let tripID { return "trip:\(tripID)" }
        if let vehicleID { return "vehicle:\(vehicleID)" }
        return nil
    }
}

/// The bus an occurrence is aiming at, saved on the alarm as lockedArrival
/// with the same fields as the app's LockedArrival.
struct LockedArrival {
    var source: String
    var routeNumber: String
    var tripID: String?
    var vehicleID: String?
    var arrivalEpochSeconds: Int
    var lockedAtEpochSeconds: Int
    var lastSeenEpochSeconds: Int

    var isLive: Bool { source == "live" }
    var arrival: Date { Date(timeIntervalSince1970: TimeInterval(arrivalEpochSeconds)) }
    var identity: String? {
        if let tripID { return "trip:\(tripID)" }
        if let vehicleID { return "vehicle:\(vehicleID)" }
        return nil
    }

    init(candidate: ArrivalCandidate, now: Date) {
        source = candidate.isLive ? "live" : "timetable"
        routeNumber = candidate.routeNumber
        tripID = candidate.tripID
        vehicleID = candidate.vehicleID
        arrivalEpochSeconds = Int(candidate.arrival.timeIntervalSince1970)
        lockedAtEpochSeconds = Int(now.timeIntervalSince1970)
        lastSeenEpochSeconds = Int(now.timeIntervalSince1970)
    }

    init?(json: Any?) {
        guard let json = json as? [String: Any],
              let arrival = (json["arrivalEpochSeconds"] as? NSNumber)?.intValue else { return nil }
        source = json["source"] as? String ?? "timetable"
        routeNumber = json["routeNumber"] as? String ?? ""
        tripID = json["tripId"] as? String
        vehicleID = json["vehicleId"] as? String
        arrivalEpochSeconds = arrival
        lockedAtEpochSeconds = (json["lockedAtEpochSeconds"] as? NSNumber)?.intValue ?? arrival
        lastSeenEpochSeconds = (json["lastSeenEpochSeconds"] as? NSNumber)?.intValue ?? arrival
    }

    /// This bus seen again as [candidate]: its newest time and source.
    func seen(as candidate: ArrivalCandidate, now: Date) -> LockedArrival {
        var updated = self
        if candidate.isLive { updated.source = "live" }
        updated.tripID = tripID ?? candidate.tripID
        updated.vehicleID = vehicleID ?? candidate.vehicleID
        updated.arrivalEpochSeconds = Int(candidate.arrival.timeIntervalSince1970)
        updated.lastSeenEpochSeconds = Int(now.timeIntervalSince1970)
        return updated
    }

    var json: [String: Any] {
        [
            "source": source,
            "routeNumber": routeNumber,
            "tripId": tripID as Any? ?? NSNull(),
            "vehicleId": vehicleID as Any? ?? NSNull(),
            "arrivalEpochSeconds": arrivalEpochSeconds,
            "lockedAtEpochSeconds": lockedAtEpochSeconds,
            "lastSeenEpochSeconds": lastSeenEpochSeconds,
        ]
    }
}

/// What a check decided: the bus to aim at, if any.
struct LockDecision {
    var locked: LockedArrival?
    /// [locked] wasn't found this check; it's counted down to from its last
    /// known time.
    var stale = false
    /// A different bus from the one locked before this check.
    var changedBus = false
}

enum ArrivalLock {
    /// How far a timetabled bus and a live one without a trip ID (TfL) may
    /// be apart and still count as the same bus.
    static let liveMatchTolerance: TimeInterval = 10 * 60

    /// Which bus to aim at for one check; the same rules as the app's
    /// decideLock, which its unit tests cover.
    static func decide(
        candidates: [ArrivalCandidate],
        windowStart: Date,
        windowEnd: Date,
        now: Date,
        current: LockedArrival?,
        skipped: Set<String>,
        liveOnly: Bool,
        stableIDs: Bool,
        onlyAfter: Date?
    ) -> LockDecision {
        var previous = current
        // A bus the user skipped is no longer the one to aim at.
        if let identity = previous?.identity, skipped.contains(identity) { previous = nil }
        let usable = candidates.filter { candidate in
            (!liveOnly || candidate.isLive) &&
                (candidate.identity.map { !skipped.contains($0) } ?? true) &&
                (onlyAfter.map { candidate.arrival > $0 } ?? true)
        }
        func inWindow(_ arrival: Date) -> Bool { arrival >= windowStart && arrival <= windowEnd }
        let inWindowCandidates = usable.filter { inWindow($0.arrival) }.sorted { $0.arrival < $1.arrival }
        func earliest(_ pool: [ArrivalCandidate]) -> ArrivalCandidate? {
            pool.first(where: \.isLive) ?? pool.first
        }

        if !stableIDs {
            // No way to follow one bus: the latest still in the window, live
            // ones first.
            let live = inWindowCandidates.filter(\.isLive)
            guard let latest = (live.isEmpty ? inWindowCandidates : live).last else { return LockDecision() }
            let locked = LockedArrival(candidate: latest, now: now)
            return LockDecision(locked: locked, changedBus: previous?.arrivalEpochSeconds != locked.arrivalEpochSeconds)
        }

        guard let held = previous else {
            guard let pick = earliest(inWindowCandidates) else { return LockDecision() }
            return LockDecision(locked: LockedArrival(candidate: pick, now: now), changedBus: true)
        }

        let matchIndex = findLocked(held, in: usable)
        let match = matchIndex.map { usable[$0] }
        let others = inWindowCandidates.filter { candidate in
            guard let match else { return true }
            return !(candidate.arrival == match.arrival && candidate.identity == match.identity && candidate.isLive == match.isLive)
        }

        if let match {
            if inWindow(match.arrival) {
                return LockDecision(locked: held.seen(as: match, now: now))
            }
            // Now expected outside the window: another bus within it wins.
            if let other = earliest(others) {
                return LockDecision(locked: LockedArrival(candidate: other, now: now), changedBus: true)
            }
            return LockDecision(locked: held.seen(as: match, now: now))
        }

        // Missing from this check's arrivals.
        if let other = earliest(others) {
            return LockDecision(locked: LockedArrival(candidate: other, now: now), changedBus: true)
        }
        if now > held.arrival {
            // Its time has passed and it never reappeared: it's gone.
            return LockDecision(changedBus: true)
        }
        return LockDecision(locked: held, stale: true)
    }

    /// [current] among [candidates]: the same trip or vehicle, or for a
    /// timetabled lock, the closest live bus on its route without a trip ID
    /// within [liveMatchTolerance].
    private static func findLocked(_ current: LockedArrival, in candidates: [ArrivalCandidate]) -> Int? {
        for (index, candidate) in candidates.enumerated() {
            if let tripID = current.tripID, candidate.tripID == tripID { return index }
            if let vehicleID = current.vehicleID, candidate.vehicleID == vehicleID { return index }
        }
        guard !current.isLive, current.vehicleID == nil else { return nil }
        var closest: (index: Int, gap: TimeInterval)?
        for (index, candidate) in candidates.enumerated()
        where candidate.isLive && candidate.tripID == nil && candidate.routeNumber == current.routeNumber {
            let gap = abs(candidate.arrival.timeIntervalSince(current.arrival))
            guard gap <= liveMatchTolerance else { continue }
            if closest.map({ gap < $0.gap }) ?? true { closest = (index, gap) }
        }
        return closest?.index
    }

    /// The indices of [minutesBeforeArrival] whose ring time is still ahead;
    /// empty when the bus is too close for every threshold.
    static func thresholdsStillAhead(_ minutesBeforeArrival: [Int], arrival: Date, now: Date) -> [Int] {
        minutesBeforeArrival.indices.filter {
            arrival.addingTimeInterval(-TimeInterval(minutesBeforeArrival[$0] * 60)) > now
        }
    }
}
