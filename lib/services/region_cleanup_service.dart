import 'package:transport_alarm/locale_registry.dart';
import 'package:transport_alarm/models/transport_alarm.dart';
import 'package:transport_alarm/services/alarm_lifecycle_service.dart';
import 'package:transport_alarm/services/alarm_server_service.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/staleness_tracker.dart';

/// Cleans up after a region change: deletes a turned-off region's alarms
/// and data, so nothing keeps running on a timetable that's no longer
/// refreshed.
class RegionCleanupService {
  final AlarmStorageService _storage;
  late final AlarmLifecycleService _lifecycle;

  RegionCleanupService({AlarmStorageService? storage})
    : _storage = storage ?? AlarmStorageService() {
    _lifecycle = AlarmLifecycleService(storage: _storage, server: AlarmServerService());
  }

  /// The saved alarms at stops in any of [localeCodes].
  Future<List<TransportAlarm>> alarmsInRegions(Set<String> localeCodes) async =>
      (await _storage.loadAlarms())
          .where((alarm) => localeCodes.contains(alarm.localeCode))
          .toList();

  /// For each of [localeCodes]: deletes its alarms (cancelling their pings
  /// or Android alarms), its database, and its refresh records, so turning
  /// it back on downloads it afresh.
  Future<void> removeRegions(Set<String> localeCodes) async {
    for (final alarm in await alarmsInRegions(localeCodes)) {
      await _lifecycle.deleteAlarm(alarm.id);
    }
    for (final code in localeCodes) {
      await GtfsDatabase.forLocale(code).deleteLocaleData();
      await StalenessTracker().forgetLocale(code);
      final locale = LocaleRegistry.getLocales([code]).firstOrNull;
      if (locale == null) continue;
      for (final gtfsProvider in locale.gtfsProviders) {
        await gtfsProvider.forget();
      }
      for (final transitProvider in locale.transitProviders) {
        await ApiCaller.forgetProvider(transitProvider.providerCode);
      }
    }
  }
}
