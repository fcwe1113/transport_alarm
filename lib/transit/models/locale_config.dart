import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

bool _timezoneDatabaseInitialized = false;

class LocaleConfig {
  final String code;
  final String displayName;
  final String timeZoneIdentifier;

  const LocaleConfig({
    required this.code,
    required this.displayName,
    required this.timeZoneIdentifier,
  });

  DateTime nowInLocale() {
    if (!_timezoneDatabaseInitialized) {
      timezone_data.initializeTimeZones();
      _timezoneDatabaseInitialized = true;
    }
    final location = timezone.getLocation(timeZoneIdentifier);
    final now = timezone.TZDateTime.now(location);
    // Keep the locale's wall-clock components for service-date comparisons.
    return DateTime.utc(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute,
      now.second,
    );
  }
}
