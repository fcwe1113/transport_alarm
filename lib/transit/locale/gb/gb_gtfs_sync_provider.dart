import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:transport_alarm/locale_registry.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/transit/cancellation.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/download_progress.dart';
import 'package:transport_alarm/transit/services/gtfs_sync_service.dart';
import 'package:transport_alarm/transit/services/staleness_tracker.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';
import 'package:http/http.dart' as http;

/// Downloads and combines the UK GTFS archives for the ATCO areas selected
/// in Settings. Each area belongs to a BODS region; each needed region's
/// archive is downloaded in turn, and only stops in the selected areas (and
/// what serves them) are imported.
class GbGtfsSyncProvider implements GtfsSyncProvider {
  @override
  final String locale = 'gb';

  /// Required by [GtfsSyncProvider]; downloads use [_regionDownloadBaseUrl].
  @override
  final String feedUrl = 'https://data.bus-data.dft.gov.uk/api/v1/dataset/';

  /// A region's archive is at this URL plus "/(region key)/".
  static const String _regionDownloadBaseUrl =
      'https://data.bus-data.dft.gov.uk/timetable/download/gtfs-file';

  static const Duration _ttl = Duration(days: 7);

  /// Checks local data age and avoids querying BODS more often than needed.
  @override
  Future<bool> checkIsStale() async {
    if (!await GtfsDatabase.forLocale(locale).hasUsableGtfsData()) return true;
    final signature = await _areaSignature();
    if (signature == null) return true;
    return StalenessTracker().isStale(
      locale,
      StalenessTracker.gtfsProviderCode,
      maxAge: _ttl,
      signature: signature,
    );
  }

  /// The selected ATCO area codes, saved comma-separated as this locale's
  /// enabled value.
  Future<Set<String>> _selectedAreas() async =>
      ((await LocaleSelectionService().getEnabledLocales())[locale] ?? '')
          .split(",")
          .where((area) => area.isNotEmpty)
          .toSet();

  /// The selected ATCO areas, so changing them makes the data stale.
  Future<String?> _areaSignature() async {
    final selectedAreas = await _selectedAreas();
    if (selectedAreas.isEmpty) return null;
    return (selectedAreas.toList()..sort()).join(',');
  }

  /// Downloads only datasets returned for selected areas and atomically installs them.
  @override
  Future<void> syncFeed({
    ProgressCallback? onProgress,
    CancellationToken? cancelToken,
  }) async {
    // Empty codes are left out: an empty prefix would match every stop.
    final selectedAreas = await _selectedAreas();
    if (selectedAreas.isEmpty) {
      throw StateError(
        'Select at least one UK ATCO area before downloading data.',
      );
    }

    final atcoCodes = jsonDecode(
      await rootBundle.loadString("lib/transit/locale/gb/atco.json"),
    ) as Map<String, dynamic>;
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
    // Closing the client aborts an in-progress download on cancel.
    final removeCancelListener = cancelToken?.onCancel(client.close);
    try {
      // Download each region in order. The archive processing belongs inside
      // this loop so it completes before the next region is downloaded.
      final regions = requiredRegions.toList();
      for (var regionIndex = 0; regionIndex < regions.length; regionIndex++) {
        cancelToken?.throwIfCancelled();
        final region = regions[regionIndex];
        final isLastRegion = regionIndex == regions.length - 1;
        final regionKey = region.toLowerCase().replaceAll(RegExp(r'\s+'), '_');
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

        await downloadToFile(
          response,
          zipFile,
          fileName: '$region.zip',
          onProgress: onProgress,
        );

        // Imported before the next download, keeping one archive on disk at
        // a time. Stops are filtered by area here; the sync service then keeps
        // only the trips, routes and services that touch those stops. Every
        // region but the last is staged without committing, so the regions
        // are swapped in together.
        try {
          final db = GtfsDatabase.forLocale(locale);
          int? stopIdColumn;
          await db.refreshAtomically((stagingDatabase) async {
            final syncService = GtfsSyncService(
              locale: locale,
              database: stagingDatabase,
              cancelToken: cancelToken,
            );
            await syncService.parseAndStoreGtfsArchive(
              zipFile,
              onProgress,
              interpolateMissingArrivalTimes: LocaleRegistry.getLocale(locale)
                  .matchingRequired,
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
          }, deferCommit: !isLastRegion, cancelToken: cancelToken);
        } finally {
          if (await zipFile.exists()) await zipFile.delete();
        }
      }
    } finally {
      removeCancelListener?.call();
      client.close();
      if (await workDirectory.exists()) {
        await workDirectory.delete(recursive: true);
      }
    }

    await StalenessTracker().markRefreshed(
      locale,
      StalenessTracker.gtfsProviderCode,
      signature: await _areaSignature(),
    );
  }
}
