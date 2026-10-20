import 'package:transport_alarm/transit/locale/hk/hk_locale.dart';
import 'package:transport_alarm/transit/locale/transit_locale.dart';
import 'package:transport_alarm/transit/locale/gb/gb_locale.dart';
import 'package:transport_alarm/transit/transit_provider.dart';

class LocaleRegistry {
  static final Map<String, TransitLocale> _supportedLocales = {
    "hk": HkLocale(),
    "gb": GbLocale(),
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

  /// The provider [providerCode] in [locale], or null when this build
  /// doesn't know the locale or provider.
  static TransitProvider? provider(String locale, String providerCode) =>
      _supportedLocales[locale]?.transitProviders
          .where((p) => p.providerCode == providerCode)
          .firstOrNull;

  static List<TransitLocale> getSupportedLocales() {
    return _supportedLocales.values.toList();
  }
}
