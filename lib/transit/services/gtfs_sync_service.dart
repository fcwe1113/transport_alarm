import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/services/csv_stream_parser.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:path/path.dart' as p;

abstract class GtfsSyncProvider {
  /// Locale code whose timetable database this provider manages.
  String get locale;

  /// Source URL for the provider's GTFS archive.
  String get feedUrl;

  /// Downloads and installs a complete provider feed.
  Future<void> syncFeed({ProgressCallback? onProgress});

  /// Reports whether the local feed should be downloaded again.
  Future<bool> checkIsStale();
}

class GtfsSyncService {
  final String locale;
  final GtfsDatabase _db;
  final Set<String>? atcoAreaCodes;

  GtfsSyncService({
    required this.locale,
    GtfsDatabase? database,
    this.atcoAreaCodes,
  }) : _db = database ?? GtfsDatabase.forLocale(locale);

  /// Extracts a GTFS archive, filters its records, and stores a usable snapshot.
  Future<void> parseAndStoreGtfsArchive(
    File zipFile,
    ProgressCallback? onProgress,
  ) async {
    onProgress?.call(AppStrings.text('transit.gtfs_updating'), null);
    const requiredFiles = [
      "routes.txt",
      "trips.txt",
      "stops.txt",
      "stop_times.txt",
    ]; // only read required files
    const optionalCalendarFiles = ['calendar.txt', 'calendar_dates.txt'];
    final inputStream = InputFileStream(zipFile.path);
    try {
      final archive = ZipDecoder().decodeStream(inputStream);
      final validFilesByName = {
        for (final file in archive.files)
          if (requiredFiles.contains(p.basename(file.name)) ||
              optionalCalendarFiles.contains(p.basename(file.name)))
            p.basename(file.name): file,
      };
      final missingFiles = requiredFiles.where(
        (name) => !validFilesByName.containsKey(name),
      );
      if (missingFiles.isNotEmpty) {
        throw FormatException(
          'GTFS archive is missing required files: ${missingFiles.join(', ')}',
        );
      }

      final calendarFiles = optionalCalendarFiles
          .where(validFilesByName.containsKey)
          .toList();
      if (calendarFiles.isEmpty) {
        throw const FormatException(
          'GTFS archive must contain calendar.txt or calendar_dates.txt.',
        );
      }
      final archiveFiles = [...requiredFiles, ...calendarFiles];

      final processingOrder = atcoAreaCodes == null
          ? archiveFiles
          : const [
              'stops.txt',
              'stop_times.txt',
              'trips.txt',
              'routes.txt',
              'calendar.txt',
              'calendar_dates.txt',
            ].where(validFilesByName.containsKey).toList();
      if (atcoAreaCodes != null &&
          !processingOrder.contains('trips.txt') &&
          !processingOrder.contains('calendar.txt') &&
          !processingOrder.contains('calendar_dates.txt')) {
        throw StateError(
          'UK area filtering needs GTFS trips and service files.',
        );
      }
      final totalFiles = processingOrder.length;
      var processedCount = 0;
      final selectedStopIds = <String>{};
      final selectedTripIds = <String>{};
      final selectedRouteIds = <String>{};
      final selectedServiceIds = <String>{};
      final appDir = await AppGroupStorage.directory;
      final extractionDir = await Directory(appDir.path)
          .createTemp('gtfs_${locale}_');
      try {
        for (final fileName in processingOrder) {
          final file = validFilesByName[fileName]!;
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
              await streamParseAndInsert(
                extractedFile,
                _db.batchInsertRoutes,
                columns: const [
                  'route_id',
                  'route_short_name',
                  'route_long_name',
                ],
                optionalColumns: const {'route_short_name'},
                includeRow: atcoAreaCodes == null
                    ? null
                    : (row) => selectedRouteIds.contains(row[0].toString()),
              );
              break;
            case "trips.txt":
              await streamParseAndInsert(
                extractedFile,
                _db.batchInsertTrips,
                columns: const [
                  'route_id',
                  'service_id',
                  'trip_id',
                  'direction_id',
                  'trip_headsign',
                  'shape_dist_traveled',
                ],
                optionalColumns: const {
                  'direction_id',
                  'trip_headsign',
                  'shape_dist_traveled',
                },
                includeRow: atcoAreaCodes == null
                    ? null
                    : (row) => selectedTripIds.contains(row[2].toString()),
                onIncludedRow: atcoAreaCodes == null
                    ? null
                    : (row) {
                        selectedRouteIds.add(row[0].toString());
                        selectedServiceIds.add(row[1].toString());
                      },
              );
              break;
            case "calendar.txt":
              await streamParseAndInsert(
                extractedFile,
                _db.batchInsertCalendar,
                columns: const [
                  'service_id',
                  'monday',
                  'tuesday',
                  'wednesday',
                  'thursday',
                  'friday',
                  'saturday',
                  'sunday',
                  'start_date',
                  'end_date',
                ],
                includeRow: atcoAreaCodes == null
                    ? null
                    : (row) => selectedServiceIds.contains(row[0].toString()),
              );
              break;
            case "calendar_dates.txt":
              await streamParseAndInsert(
                extractedFile,
                _db.batchInsertCalendarDates,
                columns: const ['service_id', 'date', 'exception_type'],
                includeRow: atcoAreaCodes == null
                    ? null
                    : (row) => selectedServiceIds.contains(row[0].toString()),
              );
              break;
            case "stops.txt":
              await streamParseAndInsert(
                extractedFile,
                _db.batchInsertStops,
                columns: const [
                  'stop_id',
                  'stop_name',
                  'stop_lat',
                  'stop_lon',
                  'stop_code',
                ],
                optionalColumns: const {'stop_code'},
                includeRow: (row) {
                  if (atcoAreaCodes == null) return true;
                  final identifiers = [
                    row[0],
                    row[4],
                  ].map((value) => value.toString().trim());
                  final matches = identifiers.any(
                    (identifier) => atcoAreaCodes!.any(
                      (area) => identifier.startsWith(area),
                    ),
                  );
                  if (matches) selectedStopIds.add(row[0].toString());
                  return matches;
                },
              );
              break;
            case "stop_times.txt":
              await streamParseAndInsert(
                extractedFile,
                _db.batchInsertStopTimes,
                columns: const [
                  'trip_id',
                  'arrival_time',
                  'departure_time',
                  'stop_id',
                  'stop_sequence',
                ],
                includeRow: atcoAreaCodes == null
                    ? null
                    : (row) => selectedStopIds.contains(row[3].toString()),
                onIncludedRow: atcoAreaCodes == null
                    ? null
                    : (row) => selectedTripIds.add(row[0].toString()),
              );
              break;
          }
          processedCount++;
        }

        onProgress?.call(AppStrings.text('transit.gtfs_interpolating'), null);
        if (atcoAreaCodes != null && selectedStopIds.isEmpty) {
          throw StateError(
            'The UK timetable contains no stops for the selected ATCO areas.',
          );
        }
        await _db.interpolateMissingArrivalTimes();
        if (atcoAreaCodes != null) {
          await _db.removeUnreferencedGtfsRows();
          await _db.materializeUkOperatorData();
        }
      } finally {
        await extractionDir.delete(recursive: true);
      }
    } finally {
      inputStream.close();
    }
  }
}
