import 'package:transport_alarm/locale_registry.dart';
import 'package:timezone/timezone.dart' as tz;

/// One timetabled arrival of a trip at a stop, from GTFS stop_times.
class ScheduledDeparture {
  final String routeShortName;
  /// "HH:MM:SS" on the locale's clock, from the start of the service day.
  /// GTFS allows hours past 24 for trips running after midnight.
  final String arrivalTime;
  /// The trip's last stop, keyed by language code.
  final Map<String, String> destination;
  final int? directionId;
  final String? tripId;
  final String locale;

  const ScheduledDeparture({
    required this.routeShortName,
    required this.arrivalTime,
    required this.destination,
    this.directionId,
    this.tripId,
    required this.locale,
  });

  /// Whole minutes from now until [arrivalTime] today; negative once passed.
  int get minutesFromNow {
    final parts = arrivalTime.split(":");
    final hours = int.parse(parts[0]);
    final minutes = int.parse(parts[1]);
    final config = LocaleRegistry.getLocale(locale).config;
    final now = config.nowInLocale();
    final location = tz.getLocation(config.timeZoneIdentifier);
    // GTFS stop_times use the agency's local clock. Anchor them to midnight
    // in that timezone, rather than UTC midnight (which is off by an hour in
    // the UK during daylight saving time).
    final serviceDayStart = tz.TZDateTime(
      location,
      now.year,
      now.month,
      now.day,
    );
    final scheduledDateTime = serviceDayStart.add(
      Duration(hours: hours, minutes: minutes),
    );

    return scheduledDateTime.difference(now).inMinutes;
  }
}
