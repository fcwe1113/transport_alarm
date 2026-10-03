import 'package:transport_alarm/transit/locale/hk/providers/ctb_provider.dart';
import 'package:transport_alarm/transit/locale/hk/providers/kmb_provider.dart';
import 'package:transport_alarm/transit/locale/uk/providers/uk_provider.dart';
import 'package:transport_alarm/transit/models/locale_config.dart';
import 'package:transport_alarm/transit/transit_provider.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';

final ApiCaller _apiCaller = ApiCaller();

final Map<String, List<TransitProvider>> providersByLocale = {
  'hk': [KmbProvider(_apiCaller), CtbProvider(_apiCaller)],
  // UK timetable data comes from a national GTFS feed, selected by ATCO area.
  'uk': [UkProvider()],
  // 'nyc': [MtaProvider()],  // future
};

const Map<String, LocaleConfig> localeConfigs = {
  "hk": LocaleConfig(
    code: "hk",
    displayName: "Hong Kong",
    timeZoneIdentifier: "Asia/Hong_Kong",
  ),
  "uk": LocaleConfig(
    code: "uk",
    displayName: "United Kingdom",
    timeZoneIdentifier: "Europe/London",
  ),
};

List<TransitProvider> get availableProviders =>
    providersByLocale.values.expand((providers) => providers).toList();

List<TransitProvider> providersForLocales(List<String> locales) {
  // todo may fix later
  return locales
      .expand((locale) => providersByLocale[locale] ?? <TransitProvider>[])
      .toList();
}
