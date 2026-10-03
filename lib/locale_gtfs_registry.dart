import 'package:transport_alarm/transit/locale/hk/hk_gtfs_sync_provider.dart';
import 'package:transport_alarm/transit/locale/uk/uk_gtfs_sync_provider.dart';
import 'package:transport_alarm/transit/services/gtfs_sync_service.dart';

class LocaleGtfsRegistry {
  static final Map<String, List<GtfsSyncProvider>> _providers = {
    "hk": [HkGtfsSyncProvider()],
    "uk": [UkGtfsSyncProvider()],
  };

  /// Returns every GTFS downloader registered for the requested locales.
  static List<GtfsSyncProvider> getProvidersForLocale(List<String> locales) {
    final List<GtfsSyncProvider> matchProviders = [];
    for (final locale in locales) {
      if (_providers.containsKey(locale)) {
        matchProviders.addAll(_providers[locale]!);
      }
    }
    return matchProviders;
  }
}
