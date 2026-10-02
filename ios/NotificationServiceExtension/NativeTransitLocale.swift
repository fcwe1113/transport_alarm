import Foundation

/// Region-specific settings used by native alarm and GTFS calculations.
/// Register one configuration per locale supported by the extension.
struct NativeTransitLocale {
    /// Stable locale key stored with each alarm, for example `hk`.
    let code: String

    /// IANA timezone identifier used for local service dates and repeat times.
    let timeZoneIdentifier: String

    /// Relative path from the shared App Group directory to this locale's GTFS DB.
    let databaseRelativePath: String

    /// Resolves the configured IANA timezone, or GMT if the identifier is invalid.
    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
    }

    /// Creates the Gregorian calendar used for GTFS service dates and repeats.
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

    /// Uses the timezone saved on the alarm, falling back to its locale for
    /// alarms created before the timezone field was added.
    static func timeZone(for alarm: [String: Any]) -> TimeZone {
        if let identifier = alarm["timeZoneIdentifier"] as? String,
           let timeZone = TimeZone(identifier: identifier) {
            return timeZone
        }
        return locale(for: alarm["localeCode"] as? String).timeZone
    }

    /// Creates a Gregorian calendar in the alarm's saved timezone.
    static func gregorianCalendar(for alarm: [String: Any]) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone(for: alarm)
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
