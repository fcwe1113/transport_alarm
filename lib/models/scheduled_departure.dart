import 'package:transport_alarm/provider_registry.dart';

class ScheduledDeparture {
  final String routeShortName;
  final String arrivalTime; // in "HH:MM:SS"
  final int? directionId;
  final String locale;

  const ScheduledDeparture ({required this.routeShortName, required this.arrivalTime, this.directionId, required this.locale});

  int get minutesFromNow {
    final parts = arrivalTime.split(":");
    final hours = int.parse(parts[0]);
    final minutes = int.parse(parts[1]);
    final now = localeConfigs[locale]!.nowInLocale(); // accounting for local gmt+8
    final serviceDayStart = DateTime.utc(now.year, now.month, now.day);
    final scheduledDateTime = serviceDayStart.add(Duration(hours: hours, minutes: minutes));

    return scheduledDateTime.difference(now).inMinutes;
  }
}