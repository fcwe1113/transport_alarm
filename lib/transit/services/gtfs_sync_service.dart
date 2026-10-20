import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:transport_alarm/transit/cancellation.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/services/csv_stream_parser.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:flutter_archive/flutter_archive.dart' as flutter_archive;

/// Where a locale's GTFS timetable comes from, and how it's downloaded and
/// imported.
abstract class GtfsSyncProvider {
  String get locale;
  String get feedUrl;

  /// Downloads the feed and swaps it into the locale database.
  Future<void> syncFeed({
    ProgressCallback? onProgress,
    CancellationToken? cancelToken,
  });

  /// Whether the installed timetable is missing or due for a refresh.
  Future<bool> checkIsStale();
}

/// Imports one GTFS archive into a (usually staging) database.
class GtfsSyncService {
  final String locale;
  final GtfsDatabase _db;
  final CancellationToken? cancelToken;

  GtfsSyncService({
    required this.locale,
    GtfsDatabase? database,
    this.cancelToken,
  }) : _db = database ?? GtfsDatabase.forLocale(locale);

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
      "agency.txt",
      "calendar_dates.txt",
    ];
    final appDir = await AppGroupStorage.directory;
    final extractionDir = await Directory(appDir.path)
        .createTemp('gtfs_${locale}_');
    try {
      await flutter_archive.ZipFile.extractToDirectory(
        zipFile: zipFile,
        destinationDir: extractionDir,
        onExtracting: (zipEntry, progress) {
          onProgress?.call(
            AppStrings.text('transit.gtfs_extracting', {
              'file': p.basename(zipEntry.name),
              'done': 0,
              'total': 0,
            }),
            progress / 100,
          );
          // Only write the files the import reads. Feeds can include large
          // extras such as shapes.txt; skipping them saves the time and
          // storage writes, still in this single native extraction pass.
          if (zipEntry.isDirectory ||
              requiredFiles.contains(p.basename(zipEntry.name))) {
            return flutter_archive.ZipFileOperation.includeItem;
          }
          return flutter_archive.ZipFileOperation.skipItem;
        },
      );

      // Build the importer map from the files already extracted to disk.
      // Avoid decoding/extracting the same ZIP entries a second time.
      final extractedFiles = <String, File>{};
      await for (final entity in extractionDir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final fileName = p.basename(entity.path);
        if (requiredFiles.contains(fileName)) {
          extractedFiles.putIfAbsent(fileName, () => entity);
        }
      }

      final foundFiles = extractedFiles.keys.toSet();
      final missingFiles = requiredFiles.where(
        (name) => !foundFiles.contains(name),
      );
      if (missingFiles.isNotEmpty) {
        throw FormatException(
          'GTFS archive is missing required files: ${missingFiles.join(', ')}',
        );
      }

      await _importFiles(
        extractedFiles,
        stopFilter,
        onProgress,
        extractedFiles.length,
      );

      if (interpolateMissingArrivalTimes) {
        onProgress?.call(AppStrings.text('transit.gtfs_interpolating'), null);
        await _db.interpolateMissingArrivalTimes(cancelToken: cancelToken);
      }
    } finally {
      if (await extractionDir.exists()) {
        await extractionDir.delete(recursive: true);
      }
    }
  }

  /// Imports filtered files in dependency order, tracking relationship IDs so
  /// unrelated GTFS rows are never inserted. Stop, route and service IDs are
  /// few enough (tens of thousands at most) to keep in memory; trip IDs,
  /// which can run to hundreds of thousands, use a disk-backed index.
  Future<void> _importFiles(
    Map<String, File> files,
    bool Function(List<dynamic> header, List<dynamic> row)? stopFilter,
    ProgressCallback? onProgress,
    int totalFiles,
  ) async {
    final indexes = <_TemporaryIndex>[];
    try {
      final includedStopIds = <String>{};
      final includedTripIds = await _TemporaryIndex.create('trip_id');
      indexes.add(includedTripIds);
      final includedRouteIds = <String>{};
      final includedServiceIds = <String>{};
      await _importFilesWithTempIdIndex(
        files,
        stopFilter,
        onProgress,
        totalFiles,
        includedStopIds,
        includedTripIds,
        includedRouteIds,
        includedServiceIds,
      );
    } catch (e) {
      debugPrint("GTFS import failed: $e");
      rethrow;
    } finally {
      for (final index in indexes.reversed) {
        await index.dispose();
      }
    }
  }

  Future<void> _importFilesWithTempIdIndex(
    Map<String, File> files,
    bool Function(List<dynamic> header, List<dynamic> row)? stopFilter,
    ProgressCallback? onProgress,
    int totalFiles,
    Set<String> includedStopIds,
    _TemporaryIndex includedTripIds,
    Set<String> includedRouteIds,
    Set<String> includedServiceIds,
  ) async {
    final allowAllStops = stopFilter ?? (header, row) => true;
    var parsedCount = 0;

    Future<void> parseWithHeader(
      String fileName,
      Future<void> Function(List<dynamic>, List<List<dynamic>>) insertBatch, {
      bool Function(List<dynamic>, List<dynamic>)? filter,
      Future<List<List<dynamic>>> Function(List<dynamic>, List<List<dynamic>>)?
      filterBatch,
      Future<void> Function(List<dynamic>, List<List<dynamic>>)? afterBatch,
      bool reportLines = false,
      int batchSize = 2000,
    }) async {
      final file = files[fileName];
      if (file == null) return;
      await _reportParsing(onProgress, fileName, totalFiles, parsedCount);
      void Function(int)? onLinesRead;
      if (reportLines && onProgress != null) {
        onProgress(
          AppStrings.text('transit.gtfs_counting_lines', {'file': fileName}),
          null,
        );
        final totalLines = await countCsvDataLines(
          file,
          cancelToken: cancelToken,
        );
        onLinesRead = (linesRead) => onProgress(
          AppStrings.text('transit.gtfs_reading_lines', {
            'file': fileName,
            'done': linesRead,
            'total': totalLines,
          }),
          totalLines == 0 ? null : linesRead / totalLines,
        );
      }
      await streamParseAndInsertWithHeader(
        file,
        (header, rows) async {
          await insertBatch(header, rows);
          await afterBatch?.call(header, rows);
        },
        filter: filter,
        filterBatch: filterBatch,
        cancelToken: cancelToken,
        onLinesRead: onLinesRead,
        batchSize: batchSize,
      );
      parsedCount++;
      // Each file is read once. Freeing its space now, rather than when the
      // whole archive is done, lowers peak storage while the staging
      // database grows.
      try {
        await file.delete();
      } catch (_) {
        // The extraction folder is removed after the import either way.
      }
    }

    // Resolve selected stops first, applying both the caller's ATCO filter
    // and recording their IDs for the stop_times relationship.
    String Function(List<dynamic>)? stopIdOf;
    await parseWithHeader(
      'stops.txt',
      _db.batchInsertStops,
      filter: (header, row) {
        // The header is the same for every row, so find the column once.
        stopIdOf ??= _columnReader(header, 'stop_id');
        return stopIdOf!(row).isNotEmpty && allowAllStops(header, row);
      },
      afterBatch: (header, rows) async {
        final stopId = _columnReader(header, 'stop_id');
        for (final row in rows) {
          includedStopIds.add(stopId(row));
        }
      },
    );

    // Stop times establish which trips serve at least one included stop.
    await parseWithHeader(
      'stop_times.txt',
      _db.batchInsertStopTimes,
      filterBatch: (header, rows) async {
        final tripId = _columnReader(header, 'trip_id');
        final stopId = _columnReader(header, 'stop_id');
        return rows.where((row) {
          return tripId(row).isNotEmpty && includedStopIds.contains(stopId(row));
        }).toList();
      },
      afterBatch: includedTripIds.insertRows,
      reportLines: true,
      // Far fewer, larger transactions for the biggest file.
      batchSize: 25000,
    );

    // Retain only trips found in the selected stops' stop times, collecting
    // the route and service IDs needed by the remaining tables. Membership is
    // checked in the disk-backed trip ID index instead of a growing Dart set.
    await parseWithHeader(
      'trips.txt',
      _db.batchInsertTrips,
      filterBatch: (header, rows) async {
        final tripId = _columnReader(header, 'trip_id');
        final routeId = _columnReader(header, 'route_id');
        final serviceId = _columnReader(header, 'service_id');
        final candidateIds =
            rows.map(tripId).where((id) => id.isNotEmpty).toSet();
        final includedIds = await includedTripIds.findExisting(candidateIds);
        return rows.where((row) {
          return includedIds.contains(tripId(row)) &&
              routeId(row).isNotEmpty &&
              serviceId(row).isNotEmpty;
        }).toList();
      },
      afterBatch: (header, rows) async {
        final routeId = _columnReader(header, 'route_id');
        final serviceId = _columnReader(header, 'service_id');
        for (final row in rows) {
          includedRouteIds.add(routeId(row));
          includedServiceIds.add(serviceId(row));
        }
      },
      // Can run to hundreds of thousands of rows, like stop_times.
      batchSize: 25000,
    );

    await parseWithHeader('agency.txt', _db.batchInsertAgencies);

    await parseWithHeader(
      'routes.txt',
      _db.batchInsertRoutes,
      filterBatch: (header, rows) async {
        final routeId = _columnReader(header, 'route_id');
        return rows.where((row) => includedRouteIds.contains(routeId(row))).toList();
      },
    );

    await parseWithHeader(
      'calendar.txt',
      _db.batchInsertCalendar,
      filterBatch: (header, rows) async {
        final serviceId = _columnReader(header, 'service_id');
        return rows.where((row) => includedServiceIds.contains(serviceId(row))).toList();
      },
    );

    await parseWithHeader(
      'calendar_dates.txt',
      _db.batchInsertCalendarDates,
      filterBatch: (header, rows) async {
        final serviceId = _columnReader(header, 'service_id');
        return rows.where((row) => includedServiceIds.contains(serviceId(row))).toList();
      },
    );
  }

  /// Reads [name] from rows of a file with [header], finding its column once
  /// instead of on every row. Values are trimmed, as with [_csvField].
  String Function(List<dynamic> row) _columnReader(
    List<dynamic> header,
    String name,
  ) {
    final index = header.indexOf(name);
    if (index < 0) {
      throw FormatException('GTFS file is missing the $name column.');
    }
    return (row) => row.length > index ? row[index].toString().trim() : '';
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

/// Stores one GTFS identifier set in a temporary SQLite file, avoiding large
/// in-memory Dart sets while filtering dependent GTFS files.
class _TemporaryIndex {
  final Directory _directory;
  final Database _database;
  final String fieldName;

  _TemporaryIndex._(this._directory, this._database, this.fieldName);

  static Future<_TemporaryIndex> create(String name) async {
    final directory = await Directory.systemTemp.createTemp('gtfs_id_index_');
    try {
      final database = await openDatabase(
        p.join(directory.path, '$name.db'),
        version: 1,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE included_ids (id TEXT PRIMARY KEY)');
        },
      );
      // Deleted after every import, so it needs no journal or syncing.
      await database.rawQuery('PRAGMA journal_mode=OFF');
      await database.execute('PRAGMA synchronous=OFF');
      return _TemporaryIndex._(directory, database, name);
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  /// Adds one batch of IDs from the corresponding already-filtered GTFS file.
  Future<void> insertRows(
    List<dynamic> header,
    List<List<dynamic>> rows,
  ) async {
    final idColumn = header.indexOf(fieldName);
    if (idColumn < 0) {
      throw FormatException('Input file is missing $fieldName.');
    }
    final uniqueIds = <String>{};
    for (final row in rows) {
      if (row.length <= idColumn) continue;
      final id = row[idColumn].toString().trim();
      if (id.isEmpty) continue;
      uniqueIds.add(id);
    }

    var batch = _database.batch();
    var processedCount = 0;
    for (final id in uniqueIds) {
      batch.insert('included_ids', {
        'id': id,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);

      processedCount++;
      if (processedCount % 500 == 0) {
        await batch.commit(noResult: true);
        batch = _database.batch();
      }
    }
    await batch.commit(noResult: true);
  }

  /// Looks up candidate IDs in small chunks to stay below SQLite bind limits.
  Future<Set<String>> findExisting(Iterable<String> candidateIds) async {
    final ids = candidateIds.toSet().toList(growable: false);
    final matches = <String>{};
    const queryChunkSize = 500;
    for (var offset = 0; offset < ids.length; offset += queryChunkSize) {
      final end = (offset + queryChunkSize).clamp(0, ids.length);
      final chunk = ids.sublist(offset, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await _database.rawQuery(
        'SELECT id FROM included_ids WHERE id IN ($placeholders)',
        chunk,
      );
      matches.addAll(rows.map((row) => row['id'] as String));
    }
    return matches;
  }

  /// Closes and removes the temporary index after this archive is imported.
  Future<void> dispose() async {
    await _database.close();
    if (await _directory.exists()) {
      await _directory.delete(recursive: true);
    }
  }
}
