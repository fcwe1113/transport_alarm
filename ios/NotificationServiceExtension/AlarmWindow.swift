import Foundation

/// An alarm's daily time window and repeat days, read from alarms.json.
/// Times are wall-clock minutes in the device's timezone, as the app saves
/// them; a window whose end is earlier than its start crosses midnight.
struct AlarmWindow {
    let startMinutes: Int
    let endMinutes: Int
    let frequency: String
    /// Dart weekday numbers: Monday is 1, Sunday is 7.
    let weekdays: Set<Int>
    let daysOfMonth: Set<Int>

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
    }

    /// Whether an occurrence starts on the day containing [day]. One-off
    /// alarms ("none") can run on any day.
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

    /// The occurrence that starts on the day containing [day].
    func occurrence(startingOn day: Date, calendar: Calendar) -> DateInterval? {
        let dayStart = calendar.startOfDay(for: day)
        guard let start = NativeTransitLocales.date(
            minutesAfterMidnight: startMinutes,
            on: dayStart,
            calendar: calendar
        ) else { return nil }
        let endDay = endMinutes <= startMinutes
            ? calendar.date(byAdding: .day, value: 1, to: dayStart)
            : dayStart
        guard let endDay,
              let end = NativeTransitLocales.date(
                  minutesAfterMidnight: endMinutes,
                  on: endDay,
                  calendar: calendar
              ),
              end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// The occurrence containing [now], checking windows that started today
    /// and, for windows crossing midnight, yesterday.
    func activeOccurrence(at now: Date, calendar: Calendar) -> DateInterval? {
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  repeats(on: day, calendar: calendar),
                  let occurrence = occurrence(startingOn: day, calendar: calendar),
                  occurrence.start <= now, now < occurrence.end else { continue }
            return occurrence
        }
        return nil
    }

    /// The first occurrence starting after [now], within roughly a year.
    func nextOccurrence(after now: Date, calendar: Calendar) -> DateInterval? {
        for offset in 0...370 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  repeats(on: day, calendar: calendar),
                  let occurrence = occurrence(startingOn: day, calendar: calendar),
                  occurrence.start > now else { continue }
            return occurrence
        }
        return nil
    }
}
