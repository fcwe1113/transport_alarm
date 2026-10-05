import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

/// Resolves IANA timezone identifiers and returns the current time in that zone.
class TimezoneService {
  static bool _initialized = false;

  TimezoneService() {
    if (!_initialized) {
      timezone_data.initializeTimeZones();
      _initialized = true;
    }
  }

  /// Returns the current instant represented in the timezone identified by [id].
  ///
  /// [id] should be an IANA identifier such as `Asia/Hong_Kong` or
  /// `Europe/London`. An unknown identifier throws the timezone package's
  /// location lookup exception.
  DateTime getTimeByTimezone(String id) {
    final location = timezone.getLocation(id);
    return timezone.TZDateTime.now(location);
  }
}
