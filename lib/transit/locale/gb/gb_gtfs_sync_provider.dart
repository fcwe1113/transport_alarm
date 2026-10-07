import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/gtfs_sync_service.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Downloads and combines the UK GTFS archives selected in Settings.
class GbGtfsSyncProvider implements GtfsSyncProvider {
  @override
  final String locale = 'gb';

  /// The selected region key is appended to this base URL.
  @override
  final String feedUrl =
      'https://data.bus-data.dft.gov.uk/api/v1/dataset/';

  static const String _regionDownloadBaseUrl =
      'https://data.bus-data.dft.gov.uk/timetable/download/gtfs-file';

  static const Duration ttlThreshold = Duration(days: 7);
  // static const String _installedRegionsKey = 'gtfs_uk_installed_regions';
  static const int _pageSize = 100;
  static const int _areaBatchSize = 40;
  static const Duration _ttl = Duration(days: 7);

  /// Loads the BODS API key from the bundled local secrets file.
  Future<String> _apiKey() async {
    final source = await rootBundle.loadString('config/secrets.json');
    final key = jsonDecode(source)['UK_BODS_KEY'];
    return key.trim();
  }

  Future<List<String>?> _selectedRegions() async { // todo may run while null
    return (await LocaleSelectionService().getEnabledLocales())[locale]?.split(",").toList();
  }

  String _preferenceKey(String region, String suffix) =>
      'gtfs_${locale}_${region}_$suffix';

  /// Checks local data age and avoids querying BODS more often than needed.
  @override
  Future<bool> checkIsStale() async {
    if (!await GtfsDatabase.forLocale(locale).hasUsableGtfsData()) return true;
    final selectedAreas = (await LocaleSelectionService().getEnabledLocales())[locale]?.split(",").toSet();
    if (selectedAreas!.isEmpty) return true;
    final prefs = await SharedPreferences.getInstance();
    final selectionSignature = (selectedAreas.toList()..sort()).join(',');
    if (prefs.getString('gtfs_atco_selection_$locale') != selectionSignature) {
      return true;
    }
    final checkedAt = DateTime.tryParse(
      prefs.getString('gtfs_last_checked_$locale') ?? '',
    );
    if (checkedAt != null) {
      final age = DateTime.now().difference(checkedAt);
      if (!age.isNegative && age < _ttl) return false;
    }
    return true;
  }

  /// Downloads only datasets returned for selected areas and atomically installs them.
  @override
  Future<void> syncFeed({ProgressCallback? onProgress}) async {
    final selectedAreas = (await LocaleSelectionService().getEnabledLocales())[locale]?.split(",").toSet();
    if (selectedAreas!.isEmpty) {
      throw StateError(
        'Select at least one UK ATCO area before downloading data.',
      );
    }

    // get list of enables regions
    // get region zip
      // filter stops by atco code
      // import everything else by "if it touches an included stop"
      // continue of every region

    final atcoCodes = jsonDecode(await rootBundle.loadString("lib/transit/locale/gb/atco.json")) as Map<String, dynamic>;
    final requiredRegions = <String>{};
    for (final atcoCode in selectedAreas) {
      final entry = atcoCodes[atcoCode];
      if (entry is Map<String, dynamic>) {
        final region = entry['region'];
        if (region is String && region.isNotEmpty) {
          requiredRegions.add(region);
        }
      }
    }

    if (requiredRegions.isEmpty) {
      throw StateError(
        'No GTFS download regions were found for the selected ATCO areas.',
      );
    }

    final appDirectory = await AppGroupStorage.directory;
    final workDirectory = await Directory(appDirectory.path)
        .createTemp('gb_gtfs_');
    final client = http.Client();
    try {
      // Download each region in order. The archive processing belongs inside
      // this loop so it completes before the next region is downloaded.
      for (final region in requiredRegions) {
        final regionKey = region
            .toLowerCase()
            .replaceAll(RegExp(r'\s+'), '_');
        final uri = Uri.parse('$_regionDownloadBaseUrl/$regionKey/');
        final zipFile = File('${workDirectory.path}/$regionKey.zip');
        final response = await client
            .send(http.Request('GET', uri))
            .timeout(ApiCaller.requestTimeout);

        if (response.statusCode != HttpStatus.ok) {
          await response.stream.drain<void>();
          throw HttpException(
            'Failed to download $region GTFS archive '
            '(HTTP ${response.statusCode}).',
            uri: uri,
          );
        }

        await response.stream
            .timeout(ApiCaller.requestTimeout)
            .pipe(zipFile.openWrite());

        // Process/filter/import this ZIP here before the loop downloads the
        // next region. The archive is retained in workDirectory for that step.

        // use stop_id to filter stops.txt and stop_times.txt
        // use trip_id from stop_times.txt to filter service_id and route_id in trips.txt
        // use route_id in trips.txt to filter routes.txt
        // use service_id to filter calendar_dates.txt and calendar.txt

        try {
          final db = GtfsDatabase.forLocale(locale);
          int? stopIdColumn;
          await db.refreshAtomically((stagingDatabase) async {
            final syncService = GtfsSyncService(
              locale: locale,
              database: stagingDatabase,
            );
            await syncService.parseAndStoreGtfsArchive(
              zipFile,
              onProgress,
              stopFilter: (header, row) {
                stopIdColumn ??= header.indexOf('stop_id');
                if (stopIdColumn! < 0) {
                  throw const FormatException(
                    'GTFS stops.txt is missing the stop_id column.',
                  );
                }
                if (row.length <= stopIdColumn!) return false;

                final stopId = row[stopIdColumn!].toString().trim();
                return selectedAreas.any(
                  (atcoCode) => stopId.startsWith(atcoCode),
                );
              },
            );
          });
        } finally {
          if (await zipFile.exists()) await zipFile.delete();
        }
      }
    } finally {
      client.close();
    }
  }
}
