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

  /// Extracts and inserts the GTFS archive, pruning dependent rows when a stop
  /// filter is supplied. With no filter, files keep the legacy import behavior.
  Future<void> parseAndStoreGtfsArchive(
    File zipFile,
    ProgressCallback? onProgress, {
    bool interpolateMissingArrivalTimes = true,
    bool Function(List<dynamic> header, List<dynamic> row)? stopFilter,
  }) async {
    onProgress?.call(AppStrings.text('transit.gtfs_updating'), null);
    const requiredFiles = [
      'stops.txt',
      'routes.txt',
      'trips.txt',
      'calendar.txt',
      'stop_times.txt',
    ];
    final inputStream = InputFileStream(zipFile.path);
    try {
      final archive = ZipDecoder().decodeStream(inputStream);
      final relevantFiles = archive.files.where((file) {
        final name = p.basename(file.name);
        return requiredFiles.contains(name) ||
            name == 'agency.txt' ||
            (stopFilter != null && name == 'calendar_dates.txt');
      }).toList();
      final foundFiles = relevantFiles
          .map((file) => p.basename(file.name))
          .toSet();
      final missingFiles = requiredFiles.where(
        (name) => !foundFiles.contains(name),
      );
      if (missingFiles.isNotEmpty) {
        throw FormatException(
          'GTFS archive is missing required files: ${missingFiles.join(', ')}',
        );
      }

      final appDir = await AppGroupStorage.directory;
      final extractionDir = await Directory(appDir.path)
          .createTemp('gtfs_${locale}_');
      try {
        final extractedFiles = <String, File>{};
        var processedCount = 0;
        for (final archiveFile in relevantFiles) {
          final fileName = p.basename(archiveFile.name);
          final progress = processedCount / relevantFiles.length;
          onProgress?.call(
            AppStrings.text('transit.gtfs_extracting', {
              'file': fileName,
              'done': processedCount,
              'total': relevantFiles.length,
            }),
            progress,
          );

          final extractedPath = p.join(extractionDir.path, fileName);
          final output = OutputFileStream(extractedPath);
          archiveFile.writeContent(output);
          await output.close();
          extractedFiles[fileName] = File(extractedPath);
          processedCount++;
        }

        await _importFiles(
          extractedFiles,
          stopFilter,
          onProgress,
          processedCount,
        );

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

  /// Imports filtered files in dependency order, collecting IDs as each
  /// relationship is resolved so unrelated GTFS rows are never inserted.
  Future<void> _importFiles(
    Map<String, File> files,
    bool Function(List<dynamic> header, List<dynamic> row)? stopFilter,
    ProgressCallback? onProgress,
    int totalFiles,
  ) async {
    final allowAllStops = stopFilter ?? (header, row) => true;
    final includedStopIds = <String>{};
    final includedTripIds = <String>{};
    final includedRouteIds = <String>{};
    final includedServiceIds = <String>{};
    var parsedCount = 0;

    // Future<void> parse(
    //   String fileName,
    //   Future<void> Function(List<List<dynamic>>) insertBatch, {
    //   bool Function(List<dynamic>, List<dynamic>)? filter,
    //   List<dynamic> Function(List<dynamic>, List<dynamic>)? transformRow,
    // }) async {
    //   final file = files[fileName];
    //   if (file == null) return;
    //   await _reportParsing(onProgress, fileName, totalFiles, parsedCount);
    //   await streamParseAndInsert(
    //     file,
    //     insertBatch,
    //     filter: filter,
    //     transformRow: transformRow,
    //   );
    //   parsedCount++;
    // }

    Future<void> parseWithHeader(
      String fileName,
      Future<void> Function(List<dynamic>, List<List<dynamic>>) insertBatch, {
      bool Function(List<dynamic>, List<dynamic>)? filter,
    }) async {
      final file = files[fileName];
      if (file == null) return;
      await _reportParsing(onProgress, fileName, totalFiles, parsedCount);
      await streamParseAndInsertWithHeader(file, insertBatch, filter: filter);
      parsedCount++;
    }

    // Resolve selected stops first, applying both the caller's ATCO filter
    // and recording their IDs for the stop_times relationship.
    await parseWithHeader(
      'stops.txt',
      _db.batchInsertStops,
      filter: (header, row) {
        final stopId = _csvField(header, row, 'stop_id');
        if (stopId.isEmpty || !allowAllStops(header, row)) return false;
        includedStopIds.add(stopId);
        return true;
      },
    );

    // Stop times establish which trips serve at least one included stop.
    await parseWithHeader(
      'stop_times.txt',
      _db.batchInsertStopTimes,
      filter: (header, row) {
        final stopId = _csvField(header, row, 'stop_id');
        if (!includedStopIds.contains(stopId)) return false;
        final tripId = _csvField(header, row, 'trip_id');
        if (tripId.isEmpty) return false;
        includedTripIds.add(tripId);
        return true;
      },
    );

    // Retain only trips found in the selected stops' stop times, collecting
    // the route and service IDs needed by the remaining tables.
    await parseWithHeader(
      'trips.txt',
      _db.batchInsertTrips,
      filter: (header, row) {
        final tripId = _csvField(header, row, 'trip_id');
        if (!includedTripIds.contains(tripId)) return false;
        final routeId = _csvField(header, row, 'route_id');
        final serviceId = _csvField(header, row, 'service_id');
        if (routeId.isEmpty || serviceId.isEmpty) return false;
        includedRouteIds.add(routeId);
        includedServiceIds.add(serviceId);
        return true;
      },
    );

    await parseWithHeader(
      'agency.txt',
      _db.batchInsertAgencies,
      filter: (header, row) =>
          includedRouteIds.contains(_csvField(header, row, 'route_id')),
    );

    await parseWithHeader(
      'routes.txt',
      _db.batchInsertRoutes,
      filter: (header, row) =>
          includedRouteIds.contains(_csvField(header, row, 'route_id')),
    );

    await parseWithHeader(
      'calendar.txt',
      _db.batchInsertCalendar,
      filter: (header, row) =>
          includedServiceIds.contains(_csvField(header, row, 'service_id')),
    );

    await parseWithHeader(
      'calendar_dates.txt',
      _db.batchInsertCalendarDates,
      filter: (header, row) =>
          includedServiceIds.contains(_csvField(header, row, 'service_id')),
    );
  }

  String _csvField(
    List<dynamic> header,
    List<dynamic> row,
    String name, {
    bool required = true,
  }) {
    final index = header.indexOf(name);
    if (index < 0) {
      if (required) {
        throw FormatException('GTFS file is missing the $name column.');
      }
      return '';
    }
    return row.length > index ? row[index].toString().trim() : '';
  }

  Future<void> _parseAgencies(
    File file,
    Map<String, String> agencyNames, {
    Set<String>? agencyIds,
  }) async {
    await streamParseAndInsertWithHeader(
      file,
      _db.batchInsertAgencies,
      filter: agencyIds == null
          ? null
          : (header, row) {
              final agencyId = _csvField(
                header,
                row,
                'agency_id',
                required: false,
              );
              // A single-agency feed may omit agency_id from routes.txt.
              return agencyIds.contains(agencyId) || agencyIds.contains('');
            },
      transformRow: (header, row) {
        final agencyId = _csvField(header, row, 'agency_id', required: false);
        final agencyName = _csvField(header, row, 'agency_name');
        if (agencyName.isEmpty) {
          throw const FormatException(
            'GTFS agency.txt contains an empty agency_name.',
          );
        }
        agencyNames[agencyId] = agencyName;
        return [agencyId, agencyName];
      },
    );
  }

  List<dynamic> Function(List<dynamic>, List<dynamic>) _routeRowTransform(
    Map<String, String> agencyNames,
  ) => (header, row) {
    final agencyId = _csvField(header, row, 'agency_id', required: false);
    final agencyName =
        agencyNames[agencyId] ??
        (agencyId.isEmpty && agencyNames.length == 1
            ? agencyNames.values.single
            : '');
    return [
      _csvField(header, row, 'route_id'),
      agencyId,
      _csvField(header, row, 'route_short_name'),
      agencyName,
    ];
  };

  Future<void> _insertRoutes(File file, Map<String, String> agencyNames) async {
    await streamParseAndInsertWithHeader(
      file,
      _db.batchInsertRoutes,
      transformRow: _routeRowTransform(agencyNames),
    );
  }

  Future<void> _insertFile(String name, File file) async {
    switch (name) {
      case 'routes.txt':
        await streamParseAndInsertWithHeader(file, _db.batchInsertRoutes);
        break;
      case 'trips.txt':
        await streamParseAndInsertWithHeader(file, _db.batchInsertTrips);
        break;
      case 'calendar.txt':
        await streamParseAndInsertWithHeader(file, _db.batchInsertCalendar);
        break;
      case 'stops.txt':
        await streamParseAndInsertWithHeader(file, _db.batchInsertStops);
        break;
      case 'stop_times.txt':
        await streamParseAndInsertWithHeader(file, _db.batchInsertStopTimes);
        break;
    }
  }

  Future<void> _reportParsing(
    ProgressCallback? onProgress,
    String fileName,
    int totalFiles, [
    int done = 0,
  ]) async {
    onProgress?.call(
      AppStrings.text('transit.gtfs_parsing', {
        'file': fileName,
        'done': done,
        'total': totalFiles,
      }),
      totalFiles == 0 ? null : done / totalFiles,
    );
  }
}
