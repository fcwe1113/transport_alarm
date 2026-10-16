import 'package:transport_alarm/locale_registry.dart';
import 'package:timezone/timezone.dart' as tz;

class ScheduledDeparture {
  final String routeShortName;
  final String arrivalTime; // in "HH:MM:SS"
  final int? directionId;
  final String locale;

  const ScheduledDeparture({
    required this.routeShortName,
    required this.arrivalTime,
    this.directionId,
    required this.locale,
  });

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
