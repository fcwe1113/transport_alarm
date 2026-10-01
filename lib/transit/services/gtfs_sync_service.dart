import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/services/csv_stream_parser.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:path/path.dart' as p;

abstract class GtfsSyncProvider {
  String get locale;
  String get feedUrl;
  Future<void> syncFeed({ProgressCallback? onProgress});
  Future<bool> checkIsStale();
}

class GtfsSyncService {
  final String locale;
  late final GtfsDatabase _db;

  GtfsSyncService({required this.locale}) {
    _db = GtfsDatabase.forLocale(locale);
  }

  Future<void> parseAndStoreGtfsArchive(File zipFile, ProgressCallback? onProgress) async {
    onProgress?.call("Updating gtfs data", null);
    final requiredFiles = ["routes.txt", "trips.txt", "calendar.txt", "stop_times.txt", "stops.txt"]; // only read required files
    final inputStream = InputFileStream(zipFile.path);
    final archive = ZipDecoder().decodeStream(inputStream);

    final validFiles = archive.files.where((f) => requiredFiles.contains(p.basename(f.name))).toList();
    final totalFiles = validFiles.length;
    int processedCount = 0;

    final tempDir = await AppGroupStorage.directory;

    for (final file in validFiles) {
      final fileName = p.basename(file.name);
      final stepProgress = processedCount / totalFiles;
      onProgress?.call("Extracting $fileName... $processedCount/$totalFiles", stepProgress);

      final extractedPath = "${tempDir.path}/$fileName";
      final outputStream = OutputFileStream(extractedPath);
      file.writeContent(outputStream);
      await outputStream.close();

      onProgress?.call("Parsing $fileName... $processedCount/$totalFiles", stepProgress);

      final extractedFile = File(extractedPath);
      switch (fileName) {
        case "routes.txt":
          await streamParseAndInsert(extractedFile, _db.batchInsertRoutes);
          break;
        case "trips.txt":
          await streamParseAndInsert(extractedFile, _db.batchInsertTrips);
          break;
        case "calendar.txt":
          await streamParseAndInsert(extractedFile, _db.batchInsertCalendar);
          break;
        case "stops.txt":
          await streamParseAndInsert(extractedFile, _db.batchInsertStops);
          break;
        case "stop_times.txt":
          await streamParseAndInsert(extractedFile, _db.batchInsertStopTimes);
          break;
      }
      processedCount++;
    }

    onProgress?.call("interpolating schedule...", null);
    await _db.interpolateMissingArrivalTimes(); // ran here because gtfs_stop_times and gtfs_trips needs to be populated before running
  }
}
