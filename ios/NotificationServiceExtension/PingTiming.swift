import Foundation

/// Learns the second of the minute at which pings reach this phone, so rings
/// can be timed to land just before their target instead of up to a minute
/// after it. The Worker's cron runs once a minute, so pings arrive at about
/// the same second each minute.
enum PingTiming {
    private static let samplesKey = "ping_arrival_seconds"
    private static let sampleCount = 5
    /// How long before the target a ring should arrive, at the latest.
    private static let earlyMargin: TimeInterval = 5

    /// Records the second of the minute a ping arrived at.
    static func recordArrival(at date: Date) {
        guard let defaults = UserDefaults(suiteName: AppGroup.identifier) else { return }
        var samples = defaults.array(forKey: samplesKey) as? [Double] ?? []
        samples.append(date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60))
        defaults.set(Array(samples.suffix(sampleCount)), forKey: samplesKey)
    }

    /// The delay to ask the server for so the ping arrives at least
    /// [earlyMargin] before [target]. Until enough arrivals are known, it's
    /// the plain time to [target].
    static func delay(toArriveBy target: Date, now: Date = Date()) -> TimeInterval {
        guard let phase = arrivalSecond() else { return target.timeIntervalSince(now) }
        let latest = target.timeIntervalSince1970 - earlyMargin
        var arrival = (latest / 60).rounded(.down) * 60 + phase
        if arrival > latest { arrival -= 60 }
        // Aim between the cron run before that arrival and the one that sends
        // it, leaving half a minute of slack either way.
        return max(0, arrival - 30 - now.timeIntervalSince1970)
    }

    /// The median arrival second, or nil before [sampleCount] pings.
    private static func arrivalSecond() -> Double? {
        guard let samples = UserDefaults(suiteName: AppGroup.identifier)?
            .array(forKey: samplesKey) as? [Double],
            samples.count >= sampleCount else { return nil }
        // Arrivals either side of the minute (59 and 1) are 2 seconds apart,
        // not 58: move the early ones past 60 before taking the median.
        let wraps = (samples.max() ?? 0) - (samples.min() ?? 0) > 30
        let unwrapped = samples.map { wraps && $0 < 30 ? $0 + 60 : $0 }.sorted()
        return unwrapped[unwrapped.count / 2].truncatingRemainder(dividingBy: 60)
    }
}
