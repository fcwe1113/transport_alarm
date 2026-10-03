import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/gtfs_sync_service.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';

/// Downloads the national BODS timetable and keeps only selected ATCO areas.
class UkGtfsSyncProvider implements GtfsSyncProvider {
  @override
  final String locale = 'uk';

  @override
  final String feedUrl =
      'https://data.bus-data.dft.gov.uk/timetable/download/gtfs-file/all/';

  static const Duration _ttl = Duration(days: 7);

  @override
  Future<bool> checkIsStale() async {
    final database = GtfsDatabase.forLocale(locale);
    if (!await database.hasUsableGtfsData()) return true;

    final selectedAreas = await LocaleSelectionService().getEnabledAtcoCodes();
    if (selectedAreas.isEmpty) return true;

    final prefs = await SharedPreferences.getInstance();
    final checkedAt = DateTime.tryParse(
      prefs.getString('gtfs_last_checked_$locale') ?? '',
    );
    if (checkedAt != null) {
      final age = DateTime.now().difference(checkedAt);
      if (!age.isNegative && age < _ttl) return false;
    }

    try {
      final response = await ApiCaller.head(Uri.parse(feedUrl));
      if (response.statusCode < 200 || response.statusCode >= 300) return true;
      final etag = response.headers['etag'];
      final modified = response.headers['last-modified'];
      final cachedEtag = prefs.getString('gtfs_etag_$locale');
      final cachedModified = prefs.getString('gtfs_last_modified_$locale');
      if ((etag != null && etag == cachedEtag) ||
          (etag == null && modified != null && modified == cachedModified)) {
        await prefs.setString(
          'gtfs_last_checked_$locale',
          DateTime.now().toIso8601String(),
        );
        return false;
      }
    } catch (_) {
      // Fall through to a GET attempt so transient HEAD failures remain retryable.
    }
    return true;
  }

  @override
  Future<void> syncFeed({ProgressCallback? onProgress}) async {
    final atcoAreas = (await LocaleSelectionService().getEnabledAtcoCodes())
        .toSet();
    if (atcoAreas.isEmpty) {
      throw StateError(
        'Select at least one UK ATCO area before downloading data.',
      );
    }

    final directory = await AppGroupStorage.directory;
    final zipFile = File(
      '${directory.path}/gtfs_download_uk_${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    final client = http.Client();
    final http.StreamedResponse response;
    try {
      final request = http.Request('GET', Uri.parse(feedUrl));
      response = await client.send(request).timeout(ApiCaller.requestTimeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'BODS GTFS download failed: HTTP ${response.statusCode}',
        );
      }
      final sink = zipFile.openWrite();
      await response.stream.timeout(ApiCaller.requestTimeout).pipe(sink);
    } catch (_) {
      if (await zipFile.exists()) await zipFile.delete();
      rethrow;
    } finally {
      client.close();
    }

    try {
      await GtfsDatabase.forLocale(locale)
          .refreshAtomically((stagingDatabase) async {
            final syncService = GtfsSyncService(
              locale: locale,
              database: stagingDatabase,
              atcoAreaCodes: atcoAreas,
            );
            await syncService.parseAndStoreGtfsArchive(zipFile, onProgress);
          }, replaceProviderCodes: const {'uk'});
    } finally {
      if (await zipFile.exists()) await zipFile.delete();
    }

    // Cache validators only after the filtered snapshot was installed.
    final prefs = await SharedPreferences.getInstance();
    final etag = response.headers['etag'];
    final modified = response.headers['last-modified'];
    if (etag != null) await prefs.setString('gtfs_etag_$locale', etag);
    if (modified != null) {
      await prefs.setString('gtfs_last_modified_$locale', modified);
    }
    await prefs.setString(
      'gtfs_last_checked_$locale',
      DateTime.now().toIso8601String(),
    );
  }
}
