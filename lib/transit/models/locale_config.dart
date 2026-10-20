import 'package:transport_alarm/services/timezone_service.dart';

/// A transit locale's fixed settings.
class LocaleConfig {
  /// Such as "hk" or "gb"; also names the locale's database file.
  final String code;
  /// The locale's name, keyed by language code.
  final Map<String, String> displayName;
  /// The IANA timezone its timetables use, such as "Europe/London".
  final String timeZoneIdentifier;

  const LocaleConfig({
    required this.code,
    required this.displayName,
    required this.timeZoneIdentifier,
  });

  /// The current time on the locale's clock, whatever the phone's timezone.
  DateTime nowInLocale() =>
      TimezoneService().getTimeByTimezone(timeZoneIdentifier);
}
