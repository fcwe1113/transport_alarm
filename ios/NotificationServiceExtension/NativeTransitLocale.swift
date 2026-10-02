import Foundation

/// Region-specific settings used for transit APIs and GTFS service data.
/// Register one configuration per locale supported by the extension.
struct NativeTransitLocale {
    /// Stable locale key stored with each alarm, for example `hk`.
    let code: String

    /// IANA timezone identifier used for local transit service dates.
    let timeZoneIdentifier: String

    /// Relative path from the shared App Group directory to this locale's GTFS DB.
    let databaseRelativePath: String

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
    // Keep these codes aligned with the locale saved on BusAlarm in Dart.
    private static let registered: [String: NativeTransitLocale] = [
        "hk": NativeTransitLocale(
            code: "hk",
            timeZoneIdentifier: "Asia/Hong_Kong",
            databaseRelativePath: "gtfs/gtfs/hk.db"
        ),
    ]

    /// Finds a locale configuration. Existing alarms without a locale code use HK.
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

    /// Combines a calendar day with a local wall-clock minute, allowing
    /// Calendar to account for timezone offset and daylight-saving changes.
    static func date(windowStartMinutes: Int, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(
            bySettingHour: windowStartMinutes / 60,
            minute: windowStartMinutes % 60,
            second: 0,
            of: day,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}
