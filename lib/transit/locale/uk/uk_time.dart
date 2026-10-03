import 'package:timezone/timezone.dart' as timezone;
import 'package:transport_alarm/provider_registry.dart';

/// Converts a GTFS service-time value, including values after 24:00, into the
/// real instant for the UK service date and applies the current DST offset.
class UkTime {
  static DateTime departureToUtc(String arrivalTime) =>
      _departure(arrivalTime).toUtc();

  static DateTime departureToDeviceLocal(String arrivalTime) =>
      _departure(arrivalTime).toLocal();

  static timezone.TZDateTime _departure(String arrivalTime) {
    // Calling nowInLocale initializes the bundled timezone database.
    final now = localeConfigs['uk']!.nowInLocale();
    final parts = arrivalTime.split(':');
    if (parts.length < 2) {
      throw FormatException('Invalid GTFS arrival_time: $arrivalTime');
    }
    final totalSeconds =
        (int.tryParse(parts[0]) ??
                (throw FormatException('Invalid GTFS hour'))) *
            3600 +
        (int.tryParse(parts[1]) ??
                (throw FormatException('Invalid GTFS minute'))) *
            60 +
        (parts.length > 2
            ? int.tryParse(parts[2]) ??
                  (throw FormatException('Invalid GTFS second'))
            : 0);
    final serviceDate = DateTime.utc(
      now.year,
      now.month,
      now.day,
    ).add(Duration(seconds: totalSeconds));
    final location = timezone.getLocation('Europe/London');
    return timezone.TZDateTime(
      location,
      serviceDate.year,
      serviceDate.month,
      serviceDate.day,
      serviceDate.hour,
      serviceDate.minute,
      serviceDate.second,
    );
  }
}
