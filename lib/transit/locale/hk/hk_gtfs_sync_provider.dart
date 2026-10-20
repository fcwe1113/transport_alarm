import 'dart:io';

import 'package:transport_alarm/transit/cancellation.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';
import 'package:transport_alarm/transit/services/download_progress.dart';
import 'package:transport_alarm/transit/services/gtfs_sync_service.dart';
import 'package:transport_alarm/transit/services/staleness_tracker.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Hong Kong's single GTFS archive from the Transport Department. Checked
/// weekly, and only downloaded again when the server says it has changed.
class HkGtfsSyncProvider implements GtfsSyncProvider {
  @override
  final String locale = "hk";

  @override
  final String feedUrl = "https://static.data.gov.hk/td/pt-headway-en/gtfs.zip";

  static const Duration _ttl = Duration(days: 7);

  // The installed feed's HTTP validators, compared on the weekly check.
  String get _etagKey => "gtfs_etag_$locale";
  String get _lastModifiedKey => "gtfs_last_modified_$locale";

  @override
  Future<bool> checkIsStale() async {
    if (!await GtfsDatabase.forLocale(locale).hasUsableGtfsData()) {
      return true;
    }

    final tracker = StalenessTracker();
    if (!await tracker.isStale(
      locale,
      StalenessTracker.gtfsProviderCode,
      maxAge: _ttl,
    )) {
      return false;
    }

    // Past the age limit: ask the server whether the feed actually changed.
    final prefs = await SharedPreferences.getInstance();
    final cachedEtag = prefs.getString(_etagKey);
    final cacheLastModified = prefs.getString(_lastModifiedKey);

    try {
      final response = await ApiCaller.head(Uri.parse(feedUrl));
      if (response.statusCode < 200 || response.statusCode >= 300) return true;

      final serverEtag = response.headers["etag"];
      final serverLastModified = response.headers["last-modified"];
      final etagMatches =
          serverEtag != null && cachedEtag != null && serverEtag == cachedEtag;
      final modifiedMatches =
          serverLastModified != null &&
          cacheLastModified != null &&
          serverLastModified == cacheLastModified;

      // Only defer another check when the server gave us a validator that
      // matches a successfully installed feed. A changed or missing validator
      // must proceed to download, and a failed download remains retryable.
      if (etagMatches || (serverEtag == null && modifiedMatches)) {
        // Unchanged, so the installed feed counts as freshly refreshed.
        await tracker.markRefreshed(locale, StalenessTracker.gtfsProviderCode);
        return false;
      }
    } catch (_) {
      // Falls through to the download, so the caller can report a failure
      // and retry next time, instead of treating an expired check as fresh.
    }
    return true;
  }

  /// Downloads the archive, imports it into a staging database and swaps
  /// it in, then saves its validators for the next staleness check.
  @override
  Future<void> syncFeed({
    ProgressCallback? onProgress,
    CancellationToken? cancelToken,
  }) async {
    final dir = await AppGroupStorage.directory;
    final zipFile = File(
      "${dir.path}/gtfs_download_$locale.${DateTime.now().microsecondsSinceEpoch}.tmp",
    );
    final request = http.Request("GET", Uri.parse(feedUrl));
    final client = http.Client();
    // Closing the client aborts an in-progress download on cancel.
    final removeCancelListener = cancelToken?.onCancel(client.close);
    void closeClient() {
      removeCancelListener?.call();
      client.close();
    }
    final http.StreamedResponse response;
    try {
      response = await client.send(request).timeout(ApiCaller.requestTimeout);
    } catch (e) {
      closeClient();
      rethrow;
    }

    if (response.statusCode != 200) {
      closeClient();
      throw Exception(
        "failed to download GTFS feed. HTTP ${response.statusCode}",
      );
    }

    try {
      await downloadToFile(
        response,
        zipFile,
        fileName: 'gtfs.zip',
        onProgress: onProgress,
      );
    } catch (_) {
      if (await zipFile.exists()) await zipFile.delete();
      rethrow;
    } finally {
      closeClient();
    }

    try {
      cancelToken?.throwIfCancelled();
      final db = GtfsDatabase.forLocale(locale);
      await db.refreshAtomically((stagingDatabase) async {
        final syncService = GtfsSyncService(
          locale: locale,
          database: stagingDatabase,
          cancelToken: cancelToken,
        );
        await syncService.parseAndStoreGtfsArchive(zipFile, onProgress);
      }, cancelToken: cancelToken);
    } finally {
      if (await zipFile.exists()) await zipFile.delete();
    }

    final prefs = await SharedPreferences.getInstance();
    final etag = response.headers["etag"];
    final lastModified = response.headers["last-modified"];

    if (etag != null) await prefs.setString(_etagKey, etag);
    if (lastModified != null) await prefs.setString(_lastModifiedKey, lastModified);
    await StalenessTracker().markRefreshed(
      locale,
      StalenessTracker.gtfsProviderCode,
    );
  }
}
