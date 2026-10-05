import 'package:transport_alarm/services/timezone_service.dart';

class LocaleConfig {
  final String code;
  final String displayName;
  final String timeZoneIdentifier;

  const LocaleConfig({
    required this.code,
    required this.displayName,
    required this.timeZoneIdentifier,
  });

  DateTime nowInLocale() =>
      TimezoneService().getTimeByTimezone(timeZoneIdentifier);
}
