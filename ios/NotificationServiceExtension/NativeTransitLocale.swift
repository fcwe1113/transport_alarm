import Foundation

/// Region-specific settings used for transit APIs and GTFS service data.
/// Register one configuration per locale supported by the extension.
struct NativeTransitLocale {
    /// Stable locale key stored with each alarm, for example `hk`.
    let code: String

    /// IANA timezone identifier used for local transit service dates.
    let timeZoneIdentifier: String

    /// This locale's GTFS database in the shared App Group directory, which
    /// the app keeps at gtfs/<code>.db.
    func databaseURL(in appGroupDirectory: URL) -> URL {
        appGroupDirectory.appendingPathComponent("gtfs/\(code).db")
    }

    /// Resolves the configured IANA timezone, or GMT if the identifier is invalid.
    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
    }

    /// Creates the Gregorian calendar used for GTFS service dates.
    var gregorianCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

enum NativeTransitLocales {
    // Keep these codes aligned with TransportAlarm.localeCode in Dart.
    private static let registered: [String: NativeTransitLocale] = [
        "hk": NativeTransitLocale(code: "hk", timeZoneIdentifier: "Asia/Hong_Kong"),
        "gb": NativeTransitLocale(code: "gb", timeZoneIdentifier: "Europe/London"),
    ]

    /// Finds a locale configuration; an unknown or missing code means HK, as
    /// TransportAlarm.fromJson defaults it.
    static func locale(for code: String?) -> NativeTransitLocale {
        guard let code, let locale = registered[code] else {
            return registered["hk"]!
        }
        return locale
    }

    /// Alarm wall-clock times follow the device timezone, independent of the
    /// locale used by the transit operator or bus stop.
    static var deviceTimeZone: TimeZone {
        .autoupdatingCurrent
    }

    /// Creates a Gregorian calendar in the device's current timezone.
    static func gregorianCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = deviceTimeZone
        return calendar
    }

    /// Combines a calendar day with a wall-clock time in minutes after
    /// midnight, letting Calendar handle the timezone and daylight saving.
    static func date(minutesAfterMidnight minutes: Int, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(
            bySettingHour: minutes / 60,
            minute: minutes % 60,
            second: 0,
            of: day,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}
