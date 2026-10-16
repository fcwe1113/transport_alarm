import 'dart:io';

import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/services/csv_stream_parser.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:flutter_archive/flutter_archive.dart' as FlutterArchive;

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
      "agency.txt",
      "calendar_dates.txt",
    ];
    final appDir = await AppGroupStorage.directory;
    final extractionDir = await Directory(appDir.path)
        .createTemp('gtfs_${locale}_');
    try {
      await FlutterArchive.ZipFile.extractToDirectory(
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
          return FlutterArchive.ZipFileOperation.includeItem;
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
        await _db.interpolateMissingArrivalTimes();
      }
    } finally {
      if (await extractionDir.exists()) {
        await extractionDir.delete(recursive: true);
      }
    }
  }

  /// Imports filtered files in dependency order, tracking relationship IDs in
  /// disk-backed indexes so unrelated GTFS rows are never inserted.
  Future<void> _importFiles(
    Map<String, File> files,
    bool Function(List<dynamic> header, List<dynamic> row)? stopFilter,
    ProgressCallback? onProgress,
    int totalFiles,
  ) async {
    final indexes = <_TemporaryIndex>[];
    try {
      final includedStopIds = await _TemporaryIndex.create('stop_id');
      indexes.add(includedStopIds);
      final includedTripIds = await _TemporaryIndex.create('trip_id');
      indexes.add(includedTripIds);
      final includedRouteIds = await _TemporaryIndex.create('route_id');
      indexes.add(includedRouteIds);
      final includedServiceIds = await _TemporaryIndex.create('service_id');
      indexes.add(includedServiceIds);
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
      print("import files with temp id index error: ${e.toString()}");
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
    _TemporaryIndex includedStopIds,
    _TemporaryIndex includedTripIds,
    _TemporaryIndex includedRouteIds,
    _TemporaryIndex includedServiceIds,
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
    }) async {
      final file = files[fileName];
      if (file == null) return;
      await _reportParsing(onProgress, fileName, totalFiles, parsedCount);
      await streamParseAndInsertWithHeader(
        file,
        (header, rows) async {
          await insertBatch(header, rows);
          await afterBatch?.call(header, rows);
        },
        filter: filter,
        filterBatch: filterBatch,
      );
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
        return true;
      },
      afterBatch: includedStopIds.insertRows,
    );

    // Stop times establish which trips serve at least one included stop.
    await parseWithHeader(
      'stop_times.txt',
      _db.batchInsertStopTimes,
      filterBatch: (header, rows) async {
        final stopIds = rows
            .map((row) => _csvField(header, row, 'stop_id'))
            .where((id) => id.isNotEmpty)
            .toSet();
        final selectedStopIds = await includedStopIds.findExisting(stopIds);
        return rows.where((row) {
          final tripId = _csvField(header, row, 'trip_id');
          final stopId = _csvField(header, row, 'stop_id');
          return tripId.isNotEmpty && selectedStopIds.contains(stopId);
        }).toList();
      },
      afterBatch: includedTripIds.insertRows,
    );

    // Retain only trips found in the selected stops' stop times, collecting
    // the route and service IDs needed by the remaining tables. Membership is
    // checked in the disk-backed trip ID index instead of a growing Dart set.
    await parseWithHeader(
      'trips.txt',
      _db.batchInsertTrips,
      filterBatch: (header, rows) async {
        final candidateIds = rows
            .map((row) => _csvField(header, row, 'trip_id'))
            .where((id) => id.isNotEmpty)
            .toSet();
        final includedIds = await includedTripIds.findExisting(candidateIds);
        final selectedRows = <List<dynamic>>[];
        for (final row in rows) {
          final tripId = _csvField(header, row, 'trip_id');
          if (!includedIds.contains(tripId)) continue;
          final routeId = _csvField(header, row, 'route_id');
          final serviceId = _csvField(header, row, 'service_id');
          if (routeId.isEmpty || serviceId.isEmpty) continue;
          selectedRows.add(row);
        }
        return selectedRows;
      },
      afterBatch: (header, rows) async {
        await includedRouteIds.insertRows(header, rows);
        await includedServiceIds.insertRows(header, rows);
      },
    );

    await parseWithHeader('agency.txt', _db.batchInsertAgencies);

    await parseWithHeader(
      'routes.txt',
      _db.batchInsertRoutes,
      filterBatch: (header, rows) async {
        final ids = rows
            .map((row) => _csvField(header, row, 'route_id'))
            .where((id) => id.isNotEmpty)
            .toSet();
        final includedIds = await includedRouteIds.findExisting(ids);
        return rows
            .where(
              (row) => includedIds.contains(_csvField(header, row, 'route_id')),
            )
            .toList();
      },
    );

    await parseWithHeader(
      'calendar.txt',
      _db.batchInsertCalendar,
      filterBatch: (header, rows) async {
        final ids = rows
            .map((row) => _csvField(header, row, 'service_id'))
            .where((id) => id.isNotEmpty)
            .toSet();
        final includedIds = await includedServiceIds.findExisting(ids);
        return rows
            .where(
              (row) =>
                  includedIds.contains(_csvField(header, row, 'service_id')),
            )
            .toList();
      },
    );

    await parseWithHeader(
      'calendar_dates.txt',
      _db.batchInsertCalendarDates,
      filterBatch: (header, rows) async {
        final ids = rows
            .map((row) => _csvField(header, row, 'service_id'))
            .where((id) => id.isNotEmpty)
            .toSet();
        final includedIds = await includedServiceIds.findExisting(ids);
        return rows
            .where(
              (row) =>
                  includedIds.contains(_csvField(header, row, 'service_id')),
            )
            .toList();
      },
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
