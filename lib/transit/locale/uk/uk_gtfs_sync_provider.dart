import 'dart:io';

import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/gtfs_sync_service.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Downloads and combines the UK GTFS archives selected in Settings.
class UkGtfsSyncProvider implements GtfsSyncProvider {
  @override
  final String locale = 'uk';

  /// The selected region key is appended to this base URL.
  @override
  final String feedUrl =
      'https://data.bus-data.dft.gov.uk/timetable/download/gtfs-file/';

  static const Duration ttlThreshold = Duration(days: 7);
  static const String _installedRegionsKey = 'gtfs_uk_installed_regions';

  // Keep this in sync with the hardcoded region names in Settings.
  static const Set<String> _supportedRegions = {
    'east_midlands',
    'east_of_england',
    'london',
    'north_east',
    'north_west',
    'northern_ireland',
    'scotland',
    'south_east',
    'south_west',
    'wales',
    'west_midlands',
    'yorkshire_and_the_humber',
  };

  Future<List<String>> _selectedRegions() async {
    final selected = await LocaleSelectionService().getEnabledUkRegions();
    return selected.where(_supportedRegions.contains).toSet().toList()..sort();
  }

  String _regionUrl(String region) => '$feedUrl$region';

  String _preferenceKey(String region, String suffix) =>
      'gtfs_${locale}_${region}_$suffix';

  @override
  Future<bool> checkIsStale() async {
    final regions = await _selectedRegions();
    if (regions.isEmpty) return false;

    final database = GtfsDatabase.forLocale(locale);
    if (!await database.hasUsableGtfsData()) return true;

    final prefs = await SharedPreferences.getInstance();
    final installedRegions = prefs.getString(_installedRegionsKey);
    if (installedRegions != regions.join(',')) return true;

    for (final region in regions) {
      final lastCheckedValue = prefs.getString(
        _preferenceKey(region, 'last_checked'),
      );
      final lastChecked = lastCheckedValue == null
          ? null
          : DateTime.tryParse(lastCheckedValue);
      if (lastChecked == null) return true;

      final age = DateTime.now().difference(lastChecked);
      if (age.isNegative || age >= ttlThreshold) return true;
    }

    return false;
  }

  @override
  Future<void> syncFeed({ProgressCallback? onProgress}) async {
    final regions = await _selectedRegions();
    if (regions.isEmpty) return;

    final storageDirectory = await AppGroupStorage.directory;
    final db = GtfsDatabase.forLocale(locale);

    // Build one complete snapshot so a failed region cannot leave a partial
    // collection of regional timetables installed on the device.
    await db.refreshAtomically((stagingDatabase) async {
      final syncService = GtfsSyncService(
        locale: locale,
        database: stagingDatabase,
      );

      for (final region in regions) {
        final zipFile = File(
          '${storageDirectory.path}/gtfs_${locale}_${region}_'
          '${DateTime.now().microsecondsSinceEpoch}.tmp',
        );
        try {
          await _downloadRegion(region, zipFile);
          await syncService.parseAndStoreGtfsArchive(
            zipFile,
            onProgress,
            interpolateMissingArrivalTimes: false,
          );
        } finally {
          if (await zipFile.exists()) await zipFile.delete();
        }
      }

      // Interpolate once after all selected regions have been merged.
      await stagingDatabase.interpolateMissingArrivalTimes();
    });

    // Mark region feeds fresh only after every selected archive is installed.
    final prefs = await SharedPreferences.getInstance();
    for (final region in regions) {
      await prefs.setString(
        _preferenceKey(region, 'last_checked'),
        DateTime.now().toIso8601String(),
      );
    }
    await prefs.setString(_installedRegionsKey, regions.join(','));
  }

  Future<void> _downloadRegion(String region, File zipFile) async {
    final request = http.Request('GET', Uri.parse(_regionUrl(region)));
    final client = http.Client();
    try {
      final response = await client
          .send(request)
          .timeout(ApiCaller.requestTimeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.stream.timeout(ApiCaller.requestTimeout).drain<void>();
        throw HttpException(
          'UK GTFS download for $region failed: HTTP ${response.statusCode}',
          uri: Uri.parse(_regionUrl(region)),
        );
      }

      final sink = zipFile.openWrite();
      try {
        await response.stream.timeout(ApiCaller.requestTimeout).pipe(sink);
      } catch (_) {
        await sink.close();
        rethrow;
      }
    } finally {
      client.close();
    }
  }
}
