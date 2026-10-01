import 'dart:io';

import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
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
    final prefs = await SharedPreferences.getInstance();
    final lastCheckedStr = prefs.getString("gtfs_last_checked_$locale");
    final cachedEtag = prefs.getString("gtfs_etag_$locale");
    final cacheLastModified = prefs.getString("gtfs_last_modified_$locale");

    if (lastCheckedStr != null) {
      final lastChecked = DateTime.tryParse(lastCheckedStr);
      if (lastChecked != null && DateTime.now().difference(lastChecked) < ttlThreshhold){
        return false;
      }
    }

    try {
      final response = await http.head(Uri.parse(feedUrl));
      if (response.statusCode == 200) {
        final serverEtag = response.headers["etag"];
        final serverLastModified = response.headers["last-modified"];

        await prefs.setString("gtfs_last_checked_$locale", DateTime.now().toIso8601String());

        if (serverEtag != null && serverEtag == cachedEtag) return false;
        if (serverLastModified != null && serverLastModified == cacheLastModified) return false;
      }
    } catch (_) {
      return false; // return false on network fail, maybe add error message later
    }

    return true;
  }

  @override
  Future<void> syncFeed({ProgressCallback? onProgress}) async {
    final dir = await AppGroupStorage.directory;
    final zipFile = File("${dir.path}/gtfs_download.zip");
    final request = http.Request("GET", Uri.parse(feedUrl));
    final client = http.Client();
    final http.StreamedResponse response;
    try {
      response = await client.send(request);
    } catch (e) {
      client.close();
      rethrow;
    }

    if (response.statusCode != 200) {
      client.close();
      throw Exception("failed to download GTFS feed. HTTP ${response.statusCode}");
    }

    final sink = zipFile.openWrite();
    await response.stream.pipe(sink);
    await sink.close();
    client.close();

    final db = GtfsDatabase.forLocale(locale);
    await db.resetDatabase(); // todo stop deleting database on data update post alpha

    final syncService = GtfsSyncService(locale: locale);
    await syncService.parseAndStoreGtfsArchive(zipFile, onProgress);

    final prefs = await SharedPreferences.getInstance();
    final etag = response.headers["etag"];
    final lastModified = response.headers["last-modified"];

    if (etag != null) await prefs.setString("gtfs_etag_$locale", etag);
    if (lastModified != null) await prefs.setString("gtfs_last_modified_$locale", lastModified);
    await prefs.setString("gtfs_last_checked_$locale", DateTime.now().toIso8601String());
  }
}
