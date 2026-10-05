import 'package:transport_alarm/transit/locale/hk/hk_gtfs_sync_provider.dart';
import 'package:transport_alarm/transit/locale/hk/hk_locale.dart';
import 'package:transport_alarm/transit/locale/transit_locale.dart';
import 'package:transport_alarm/transit/locale/uk/uk_gtfs_sync_provider.dart';
import 'package:transport_alarm/transit/services/gtfs_sync_service.dart';

class LocaleRegistry {
  static final Map<String, TransitLocale> _supportedLocales = {
    "hk": HkLocale(),
    // "uk": [UkGtfsSyncProvider()],
  };

  static List<TransitLocale> getLocales(List<String> locales) {
    final List<TransitLocale> matchLocales = [];
    for (final locale in locales) {
      if (_supportedLocales.containsKey(locale)) {
        matchLocales.add(_supportedLocales[locale]!);
      }
    }
    return matchLocales;
  }

  static TransitLocale getLocale(String locale) {
    return _supportedLocales[locale]!;
  }

  static List<TransitLocale> getSupportedLocales() {
    return _supportedLocales.values.toList();
  }
}
