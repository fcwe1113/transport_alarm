import 'package:transport_alarm/transit/locale/hk/hk_locale.dart';
import 'package:transport_alarm/transit/locale/transit_locale.dart';
import 'package:transport_alarm/transit/locale/gb/gb_locale.dart';
import 'package:transport_alarm/transit/transit_provider.dart';

/// Every transit region the app supports, keyed by locale code. Adding a
/// region means implementing TransitLocale and listing it here.
class LocaleRegistry {
  static final Map<String, TransitLocale> _supportedLocales = {
    "hk": HkLocale(),
    "gb": GbLocale(),
  };

  /// The supported regions among [locales], skipping unknown codes.
  static List<TransitLocale> getLocales(List<String> locales) => [
    for (final locale in locales)
      if (_supportedLocales[locale] case final match?) match,
  ];

  /// The region for [locale]; throws if this build doesn't support it.
  static TransitLocale getLocale(String locale) => _supportedLocales[locale]!;

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
