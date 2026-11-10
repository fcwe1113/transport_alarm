import 'package:transport_alarm/locale_registry.dart';
import 'package:transport_alarm/models/transport_alarm.dart';

/// Whether every route of [alarm] comes from a provider whose live buses
/// can be told apart (see TransitProvider.hasStableVehicleIds), so the
/// alarm can follow one bus and offer "Next bus". The iOS notification
/// extension makes the same check from the routes' provider codes.
bool canFollowOneBus(TransportAlarm alarm) {
  final providers = alarm.routeApiConfigs.isEmpty
      ? LocaleRegistry.getLocale(alarm.localeCode).transitProviders
      : [
          for (final config in alarm.routeApiConfigs)
            LocaleRegistry.provider(alarm.localeCode, config.providerCode),
        ];
  return providers.isNotEmpty &&
      providers.every((provider) => provider?.hasStableVehicleIds ?? false);
}
