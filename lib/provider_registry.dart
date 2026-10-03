import 'package:transport_alarm/transit/locale/hk/providers/ctb_provider.dart';
import 'package:transport_alarm/transit/locale/hk/providers/kmb_provider.dart';
import 'package:transport_alarm/transit/models/locale_config.dart';
import 'package:transport_alarm/transit/transit_provider.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';

final ApiCaller _apiCaller = ApiCaller();

final Map<String, List<TransitProvider>> providersByLocale = {
  'hk': [KmbProvider(_apiCaller), CtbProvider(_apiCaller)],
  // 'nyc': [MtaProvider()],  // future
};

const Map<String, LocaleConfig> localeConfigs = {
  "hk": LocaleConfig(
    code: "hk",
    displayName: "Hong Kong",
    utcOffset: Duration(hours: 8),
    timeZoneIdentifier: "Asia/Hong_Kong",
  ),
};

List<TransitProvider> get availableProviders => providersByLocale.values.expand((providers) => providers).toList();

List<TransitProvider> providersForLocales(List<String> locales) { // todo may fix later
  return locales.expand((locale) => providersByLocale[locale] ?? <TransitProvider>[]).toList();
}
