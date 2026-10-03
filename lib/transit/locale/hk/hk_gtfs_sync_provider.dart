import 'dart:io';

import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';
import 'package:transport_alarm/transit/services/gtfs_sync_service.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class HkGtfsSyncProvider implements GtfsSyncProvider {
  @override
  final String locale = "hk";

  @override
  final String feedUrl = "https://static.data.gov.hk/td/pt-headway-en/gtfs.zip";

  static const Duration ttlThreshhold = Duration(days: 7);

  @override
  Future<bool> checkIsStale() async {
    if (!await GtfsDatabase.forLocale(locale).hasUsableGtfsData()) {
      return true;
    }

    final prefs = await SharedPreferences.getInstance();
    final lastCheckedStr = prefs.getString("gtfs_last_checked_$locale");
    final cachedEtag = prefs.getString("gtfs_etag_$locale");
    final cacheLastModified = prefs.getString("gtfs_last_modified_$locale");

    if (lastCheckedStr != null) {
      final lastChecked = DateTime.tryParse(lastCheckedStr);
      if (lastChecked != null) {
        final age = DateTime.now().difference(lastChecked);
        if (!age.isNegative && age < ttlThreshhold) return false;
      }
    }

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
        await prefs.setString(
          "gtfs_last_checked_$locale",
          DateTime.now().toIso8601String(),
        );
        return false;
      }
    } catch (_) {
      // Attempt the GET path so the caller can report a failure and retry next
      // time, instead of treating an expired check as fresh indefinitely.
      return true;
    }

    return true;
  }

  @override
  Future<void> syncFeed({ProgressCallback? onProgress}) async {
    final dir = await AppGroupStorage.directory;
    final zipFile = File(
      "${dir.path}/gtfs_download_$locale.${DateTime.now().microsecondsSinceEpoch}.tmp",
    );
    final request = http.Request("GET", Uri.parse(feedUrl));
    final client = http.Client();
    final http.StreamedResponse response;
    try {
      response = await client.send(request).timeout(ApiCaller.requestTimeout);
    } catch (e) {
      client.close();
      rethrow;
    }

    if (response.statusCode != 200) {
      client.close();
      throw Exception(
        "failed to download GTFS feed. HTTP ${response.statusCode}",
      );
    }

    try {
      final sink = zipFile.openWrite();
      await response.stream.timeout(ApiCaller.requestTimeout).pipe(sink);
    } catch (_) {
      if (await zipFile.exists()) await zipFile.delete();
      rethrow;
    } finally {
      client.close();
    }

    try {
      final db = GtfsDatabase.forLocale(locale);
      await db.refreshAtomically((stagingDatabase) async {
        final syncService = GtfsSyncService(
          locale: locale,
          database: stagingDatabase,
        );
        await syncService.parseAndStoreGtfsArchive(zipFile, onProgress);
      });
    } finally {
      if (await zipFile.exists()) await zipFile.delete();
    }

    final prefs = await SharedPreferences.getInstance();
    final etag = response.headers["etag"];
    final lastModified = response.headers["last-modified"];

    if (etag != null) await prefs.setString("gtfs_etag_$locale", etag);
    if (lastModified != null)
      await prefs.setString("gtfs_last_modified_$locale", lastModified);
    await prefs.setString(
      "gtfs_last_checked_$locale",
      DateTime.now().toIso8601String(),
    );
  }
}
