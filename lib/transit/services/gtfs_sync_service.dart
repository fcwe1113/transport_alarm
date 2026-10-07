import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/services/csv_stream_parser.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:path/path.dart' as p;

abstract class GtfsSyncProvider {
  String get locale;
  String get feedUrl;
  Future<void> syncFeed({ProgressCallback? onProgress});
  Future<bool> checkIsStale();
}

class GtfsSyncService {
  final String locale;
  final GtfsDatabase _db;

  GtfsSyncService({required this.locale, GtfsDatabase? database})
    : _db = database ?? GtfsDatabase.forLocale(locale);

  Future<void> parseAndStoreGtfsArchive(
    File zipFile,
    ProgressCallback? onProgress, {
    bool interpolateMissingArrivalTimes = true,
    bool Function(List<dynamic> header, List<dynamic> row)? stopFilter,
  }) async {
    onProgress?.call(AppStrings.text('transit.gtfs_updating'), null);
    final requiredFiles = [
      "stops.txt",
      "routes.txt",
      "trips.txt",
      "calendar.txt",
      "stop_times.txt",
    ]; // only read required files
    final inputStream = InputFileStream(zipFile.path);
    try {
      final archive = ZipDecoder().decodeStream(inputStream);
      final validFiles = archive.files
          .where((f) => requiredFiles.contains(p.basename(f.name)))
          .toList();
      final foundFiles = validFiles.map((f) => p.basename(f.name)).toSet();
      final missingFiles = requiredFiles.where(
        (name) => !foundFiles.contains(name),
      );
      if (missingFiles.isNotEmpty) {
        throw FormatException(
          'GTFS archive is missing required files: ${missingFiles.join(', ')}',
        );
      }

      final totalFiles = validFiles.length;
      var processedCount = 0;
      final appDir = await AppGroupStorage.directory;
      final extractionDir = await Directory(appDir.path)
          .createTemp('gtfs_${locale}_');
      try {
        for (final file in validFiles) {
          final fileName = p.basename(file.name);
          final stepProgress = processedCount / totalFiles;
          onProgress?.call(
            AppStrings.text('transit.gtfs_extracting', {
              'file': fileName,
              'done': processedCount,
              'total': totalFiles,
            }),
            stepProgress,
          );

          final extractedPath = p.join(extractionDir.path, fileName);
          final outputStream = OutputFileStream(extractedPath);
          file.writeContent(outputStream);
          await outputStream.close();

          onProgress?.call(
            AppStrings.text('transit.gtfs_parsing', {
              'file': fileName,
              'done': processedCount,
              'total': totalFiles,
            }),
            stepProgress,
          );

          final extractedFile = File(extractedPath);
          switch (fileName) {
            case "routes.txt":
              await streamParseAndInsert(extractedFile, _db.batchInsertRoutes);
              break;
            case "trips.txt":
              await streamParseAndInsert(extractedFile, _db.batchInsertTrips);
              break;
            case "calendar.txt":
              await streamParseAndInsert(
                extractedFile,
                _db.batchInsertCalendar,
              );
              break;
            case "stops.txt":
              await streamParseAndInsert(
                extractedFile,
                _db.batchInsertStops,
                filter: stopFilter,
              );
              break;
            case "stop_times.txt":
              await streamParseAndInsert(
                extractedFile,
                _db.batchInsertStopTimes,
              );
              break;
          }
          processedCount++;
        }

        if (interpolateMissingArrivalTimes) {
          onProgress?.call(AppStrings.text('transit.gtfs_interpolating'), null);
          await _db.interpolateMissingArrivalTimes();
        }
      } finally {
        await extractionDir.delete(recursive: true);
      }
    } finally {
      inputStream.close();
    }
  }
}
