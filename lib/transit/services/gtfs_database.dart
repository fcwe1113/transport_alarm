import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:transport_alarm/models/scheduled_departure.dart';
import 'package:transport_alarm/provider_registry.dart';
import 'package:transport_alarm/services/geo_utils.dart';
import 'package:transport_alarm/transit/models/transport_stop.dart';
import 'package:transport_alarm/transit/models/gtfs_stop.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:sqflite/sqflite.dart';

import '../models/transport_route.dart';

class GtfsDatabase {
  static final Map<String, GtfsDatabase> _instances = {};
  static final Map<String, Database?> _databases = {};
  static final Map<String, Future<void>> _replacementBarriers = {};
  static final Map<String, Future<void>> _refreshTails = {};
  final String locale;
  final String? _explicitDatabasePath;

  GtfsDatabase._(this.locale, {String? databasePath})
    : _explicitDatabasePath = databasePath;

  String get _cacheKey =>
      _explicitDatabasePath == null ? locale : '$locale|$_explicitDatabasePath';

  factory GtfsDatabase.forLocale(String locale) {
    return _instances.putIfAbsent(locale, () => GtfsDatabase._(locale));
  }

  factory GtfsDatabase._atPath(String locale, String path) =>
      GtfsDatabase._(locale, databasePath: path);

  Future<Database> get database async {
    if (_explicitDatabasePath == null) {
      await _replacementBarriers[locale];
    }
    if (_databases.containsKey(_cacheKey) && _databases[_cacheKey]!.isOpen) {
      return _databases[_cacheKey]!;
    }
    late final File databaseFile;
    if (_explicitDatabasePath != null) {
      databaseFile = File(_explicitDatabasePath);
      await databaseFile.parent.create(recursive: true);
    } else {
      final dir = Directory('${(await AppGroupStorage.directory).path}/gtfs');
      await dir.create(recursive: true);
      databaseFile = File('${dir.path}/$locale.db');
      final backupFile = File('${dir.path}/$locale.db.backup');
      // Recover if the process stopped between the two atomic rename steps.
      if (!await databaseFile.exists() && await backupFile.exists()) {
        await backupFile.rename(databaseFile.path);
      }
      final legacyFile = File('${dir.path}/gtfs/$locale.db');
      if (!await databaseFile.exists() && await legacyFile.exists()) {
        await legacyFile.copy(databaseFile.path);
      }
    }
    final db = await _initDB(databaseFile.path);
    _databases[_cacheKey] = db;
    return db;
  }

  /// Builds a replacement in a separate SQLite file and installs it only after
  /// the caller has populated and validated the complete snapshot.
  Future<void> refreshAtomically(
    Future<void> Function(GtfsDatabase stagingDatabase) populate, {
    Set<String> replaceProviderCodes = const {},
  }) async {
    final previousRefresh = _refreshTails[locale] ?? Future<void>.value();
    final refreshFinished = Completer<void>();
    _refreshTails[locale] = refreshFinished.future;
    await previousRefresh;

    Completer<void>? barrier;
    GtfsDatabase? stagingDb;
    File? stagingFile;
    try {
      final currentDb = await database;
      final appDir = await AppGroupStorage.directory;
      final dbDir = Directory('${appDir.path}/gtfs');
      await dbDir.create(recursive: true);
      final activeFile = File('${dbDir.path}/$locale.db');
      final backupFile = File('${dbDir.path}/$locale.db.backup');
      stagingFile = File(
        '${dbDir.path}/$locale.db.staging.${DateTime.now().microsecondsSinceEpoch}',
      );
      stagingDb = GtfsDatabase._atPath(locale, stagingFile.path);

      // Start with a fresh schema. Carry forward operator data so a timetable
      // refresh cannot temporarily erase the app's independently fetched data.
      await stagingDb.database;
      await populate(stagingDb);

      // Pause new database lookups while the auxiliary data is copied and the
      // active file is swapped. The existing timetable remains readable while
      // the new snapshot is being downloaded and built.
      barrier = Completer<void>();
      _replacementBarriers[locale] = barrier.future;
      await _copyOperatorData(
        currentDb,
        await stagingDb.database,
        replaceProviderCodes: replaceProviderCodes,
      );
      await _validateSnapshot(await stagingDb.database);
      await stagingDb.close();

      final cachedDb = _databases.remove(locale);
      if (cachedDb != null && cachedDb.isOpen) await cachedDb.close();

      if (await backupFile.exists()) await backupFile.delete();
      if (await activeFile.exists()) await activeFile.rename(backupFile.path);
      try {
        await stagingFile.rename(activeFile.path);
        final installed = await _initDB(activeFile.path);
        _databases[locale] = installed;
        await _validateSnapshot(installed);
        if (await backupFile.exists()) {
          try {
            await backupFile.delete();
          } catch (_) {
            // The installed database is already valid; a stale backup is safe.
          }
        }
      } catch (_) {
        final failedInstall = _databases.remove(locale);
        if (failedInstall != null && failedInstall.isOpen) {
          await failedInstall.close();
        }
        if (await activeFile.exists()) await activeFile.delete();
        if (await backupFile.exists()) await backupFile.rename(activeFile.path);
        rethrow;
      }
    } finally {
      try {
        if (stagingDb != null) await stagingDb.close();
        if (stagingFile != null && await stagingFile.exists()) {
          await stagingFile.delete();
        }
      } finally {
        if (barrier != null) {
          _replacementBarriers.remove(locale);
          barrier.complete();
        }
        refreshFinished.complete();
        if (identical(_refreshTails[locale], refreshFinished.future)) {
          _refreshTails.remove(locale);
        }
      }
    }
  }

  Future<void> _copyOperatorData(
    Database source,
    Database target, {
    Set<String> replaceProviderCodes = const {},
  }) async {
    final validStopRows = await target.query(
      'gtfs_stops',
      columns: ['stop_id'],
    );
    final validStopIds = validStopRows
        .map((row) => row['stop_id'] as String)
        .toSet();
    await target.transaction((txn) async {
      for (final table in ['operator_stops', 'operator_routes']) {
        final rows = await source.query(
          table,
          where: replaceProviderCodes.isEmpty
              ? null
              : 'provider_code NOT IN (${List.filled(replaceProviderCodes.length, '?').join(',')})',
          whereArgs: replaceProviderCodes.isEmpty
              ? null
              : replaceProviderCodes.toList(),
        );
        final batch = txn.batch();
        for (final row in rows) {
          batch.insert(
            table,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      }
      final routeStops = await source.rawQuery(
        replaceProviderCodes.isEmpty
            ? 'SELECT rs.* FROM route_stops rs'
            : 'SELECT rs.* FROM route_stops rs INNER JOIN operator_routes r ON r.operator_route_id = rs.operator_route_id WHERE r.provider_code NOT IN (${List.filled(replaceProviderCodes.length, '?').join(',')})',
        replaceProviderCodes.isEmpty ? null : replaceProviderCodes.toList(),
      );
      final routeBatch = txn.batch();
      for (final row in routeStops) {
        routeBatch.insert(
          'route_stops',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await routeBatch.commit(noResult: true);
      final mappings = await source.rawQuery(
        replaceProviderCodes.isEmpty
            ? 'SELECT sm.* FROM stop_mapping sm'
            : 'SELECT sm.* FROM stop_mapping sm INNER JOIN operator_stops os ON os.operator_stop_id = sm.operator_stop_id WHERE os.provider_code NOT IN (${List.filled(replaceProviderCodes.length, '?').join(',')})',
        replaceProviderCodes.isEmpty ? null : replaceProviderCodes.toList(),
      );
      final batch = txn.batch();
      for (final row in mappings) {
        if (validStopIds.contains(row['gtfs_stop_id'])) {
          batch.insert(
            'stop_mapping',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> _validateSnapshot(Database db) async {
    for (final table in [
      'gtfs_routes',
      'gtfs_trips',
      'gtfs_stops',
      'gtfs_stop_times',
    ]) {
      final result = await db.rawQuery('SELECT COUNT(*) AS count FROM $table');
      if ((result.first['count'] as int?) == null ||
          (result.first['count'] as int) == 0) {
        throw StateError('Refusing to install an empty GTFS table: $table');
      }
    }
    final calendarCounts = await db.rawQuery('''
      SELECT
        (SELECT COUNT(*) FROM gtfs_calendar) +
        (SELECT COUNT(*) FROM gtfs_calendar_dates) AS count
    ''');
    if ((calendarCounts.single['count'] as int?) == 0) {
      throw StateError(
        'Refusing to install a GTFS snapshot without service dates.',
      );
    }
  }

  Future<void> close() async {
    final db = _databases.remove(_cacheKey);
    if (db != null && db.isOpen) await db.close();
  }

  Future<Database> _initDB(String filePath) async {
    return await openDatabase(
      filePath,
      version: 5,
      onCreate: _createDB,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE gtfs_stops ADD COLUMN stop_code TEXT');
        }
        if (oldVersion < 3) {
          await db.execute('''CREATE TABLE gtfs_calendar_dates (
            service_id TEXT NOT NULL,
            date TEXT NOT NULL,
            exception_type INTEGER NOT NULL,
            PRIMARY KEY (service_id, date)
          )''');
        }
        if (oldVersion < 4) {
          await db.execute(
            'ALTER TABLE gtfs_trips ADD COLUMN trip_headsign TEXT',
          );
        }
        if (oldVersion < 5) {
          await db.execute(
            'ALTER TABLE gtfs_routes ADD COLUMN route_long_name TEXT',
          );
        }
      },
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''CREATE TABLE gtfs_routes (
    route_id TEXT PRIMARY KEY, 
    route_short_name TEXT NOT NULL,
    route_long_name TEXT
    )''');

    await db.execute('''CREATE TABLE gtfs_trips (
    trip_id TEXT PRIMARY KEY, 
    route_id TEXT NOT NULL, 
    service_id TEXT NOT NULL, 
    direction_id INTEGER,
    trip_headsign TEXT
    )''');

    await db.execute('''CREATE TABLE gtfs_calendar (
    service_id TEXT PRIMARY KEY, 
    monday INTEGER, 
    tuesday INTEGER, 
    wednesday INTEGER, 
    thursday INTEGER, 
    friday INTEGER, 
    saturday INTEGER, 
    sunday INTEGER,
    start_date TEXT, 
    end_date TEXT
    )''');

    await db.execute('''CREATE TABLE gtfs_calendar_dates (
    service_id TEXT NOT NULL,
    date TEXT NOT NULL,
    exception_type INTEGER NOT NULL,
    PRIMARY KEY (service_id, date)
    )''');

    await db.execute('''CREATE TABLE gtfs_stop_times (
    trip_id TEXT NOT NULL, 
    arrival_time TEXT NOT NULL, 
    departure_time TEXT NOT NULL, 
    stop_id TEXT NOT NULL, 
    stop_sequence INTEGER NOT NULL
    )''');

    await db.execute('''CREATE TABLE gtfs_stops (
    stop_id TEXT PRIMARY KEY, 
    stop_name TEXT NOT NULL, 
    stop_lat REAL NOT NULL, 
    stop_lon REAL NOT NULL,
    stop_code TEXT
    )''');

    await db.execute('''CREATE TABLE operator_stops (
    operator_stop_id TEXT PRIMARY KEY, 
    provider_code TEXT NOT NULL, 
    names TEXT NOT NULL DEFAULT "{}",
    lat REAL, 
    lng REAL
    )''');

    await db.execute('''CREATE TABLE operator_routes (
    operator_route_id TEXT PRIMARY KEY, 
    provider_code TEXT NOT NULL, 
    route_number TEXT NOT NULL, 
    bound TEXT, 
    names TEXT NOT NULL DEFAULT "{}",
    origin_text TEXT NOT NULL, 
    destination_text TEXT NOT NULL
    )''');

    await db.execute('''CREATE TABLE route_stops (
    operator_route_id TEXT NOT NULL REFERENCES operator_routes(operator_route_id),
    operator_stop_id TEXT NOT NULL REFERENCES operator_stops(operator_stop_id),
    stop_sequence INTEGER NOT NULL,
    PRIMARY KEY (operator_route_id, operator_stop_id, stop_sequence)
    )''');

    await db.execute('''CREATE TABLE stop_mapping (
    operator_stop_id TEXT PRIMARY KEY REFERENCES operator_stops(operator_stop_id),
    gtfs_stop_id TEXT NOT NULL REFERENCES gtfs_stops(stop_id),
    match_confidence REAL
    )''');

    await db.execute(
      '''CREATE INDEX idx_routes_name ON gtfs_routes(route_short_name)''',
    );
    await db.execute(
      '''CREATE INDEX idx_trips_route_service ON gtfs_trips(route_id, service_id)''',
    );
    await db.execute(
      '''CREATE INDEX idx_stop_times_lookup ON gtfs_stop_times(stop_id, arrival_time)''',
    );
    await db.execute(
      '''CREATE INDEX idx_operator_stops_provider ON operator_stops(provider_code)''',
    );
    await db.execute(
      '''CREATE INDEX idx_stop_times_trip ON gtfs_stop_times(trip_id)''',
    );
  }

  String _val(List<dynamic> row, int index) =>
      row.length > index ? row[index].toString() : "";

  Future<void> batchInsertRoutes(List<List<dynamic>> rows) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var row in rows) {
        batch.insert("gtfs_routes", {
          "route_id": _val(row, 0),
          "route_short_name": _val(row, 1),
          "route_long_name": _val(row, 2),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> batchInsertTrips(List<List<dynamic>> rows) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var row in rows) {
        batch.insert("gtfs_trips", {
          "route_id": _val(row, 0),
          "service_id": _val(row, 1),
          "trip_id": _val(row, 2),
          "direction_id": int.tryParse(_val(row, 3)) ?? 0,
          "trip_headsign": _val(row, 4),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> batchInsertCalendar(List<List<dynamic>> rows) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var row in rows) {
        batch.insert("gtfs_calendar", {
          "service_id": _val(row, 0),
          "monday": int.tryParse(_val(row, 1)) ?? 0,
          "tuesday": int.tryParse(_val(row, 2)) ?? 0,
          "wednesday": int.tryParse(_val(row, 3)) ?? 0,
          "thursday": int.tryParse(_val(row, 4)) ?? 0,
          "friday": int.tryParse(_val(row, 5)) ?? 0,
          "saturday": int.tryParse(_val(row, 6)) ?? 0,
          "sunday": int.tryParse(_val(row, 7)) ?? 0,
          "start_date": _val(row, 8),
          "end_date": _val(row, 9),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> batchInsertCalendarDates(List<List<dynamic>> rows) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final row in rows) {
        batch.insert('gtfs_calendar_dates', {
          'service_id': _val(row, 0),
          'date': _val(row, 1),
          'exception_type': int.tryParse(_val(row, 2)) ?? 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> batchInsertStops(List<List<dynamic>> rows) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var row in rows) {
        batch.insert("gtfs_stops", {
          "stop_id": _val(row, 0),
          "stop_name": _val(row, 1),
          "stop_lat": double.tryParse(_val(row, 2)) ?? 0,
          "stop_lon": double.tryParse(_val(row, 3)) ?? 0,
          "stop_code": _val(row, 4),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> batchInsertStopTimes(List<List<dynamic>> rows) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var row in rows) {
        batch.insert("gtfs_stop_times", {
          "trip_id": _val(row, 0),
          "arrival_time": _val(row, 1),
          "departure_time": _val(row, 2),
          "stop_id": _val(row, 3),
          "stop_sequence": int.tryParse(_val(row, 4)) ?? 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  /// Removes UK feed records that are outside the selected ATCO areas and
  /// creates the operator-facing records consumed by the app's existing UI.
  Future<void> materializeUkOperatorData() async {
    final db = await database;
    await db.transaction((txn) async {
      final stops = await txn.query('gtfs_stops');
      final stopBatch = txn.batch();
      for (final stop in stops) {
        final stopId = stop['stop_id'] as String;
        final operatorStopId = 'uk:$stopId';
        stopBatch.insert('operator_stops', {
          'operator_stop_id': operatorStopId,
          'provider_code': 'uk',
          'names': jsonEncode({'en': stop['stop_name'] ?? stopId}),
          'lat': stop['stop_lat'],
          'lng': stop['stop_lon'],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        stopBatch.insert('stop_mapping', {
          'operator_stop_id': operatorStopId,
          'gtfs_stop_id': stopId,
          'match_confidence': 1.0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await stopBatch.commit(noResult: true);

      final routeDirections = await txn.rawQuery('''
        SELECT DISTINCT t.route_id, COALESCE(t.direction_id, 0) AS direction_id,
               r.route_short_name, r.route_long_name, t.trip_headsign
        FROM gtfs_trips t
        INNER JOIN gtfs_routes r ON r.route_id = t.route_id
        INNER JOIN gtfs_stop_times st ON st.trip_id = t.trip_id
        ORDER BY t.route_id, direction_id
      ''');
      for (final routeDirection in routeDirections) {
        final routeId = routeDirection['route_id'] as String;
        final directionId = routeDirection['direction_id'] as int? ?? 0;
        final operatorRouteId = 'uk:$routeId:$directionId';
        final tripRows = await txn.query(
          'gtfs_trips',
          columns: ['trip_id'],
          where: 'route_id = ? AND COALESCE(direction_id, 0) = ?',
          whereArgs: [routeId, directionId],
          limit: 1,
        );
        if (tripRows.isEmpty) continue;
        final times = await txn.query(
          'gtfs_stop_times',
          where: 'trip_id = ?',
          whereArgs: [tripRows.first['trip_id']],
          orderBy: 'stop_sequence ASC',
        );
        if (times.isEmpty) continue;
        final routeNumber =
            (routeDirection['route_short_name'] as String?)
                    ?.trim()
                    .isNotEmpty ==
                true
            ? (routeDirection['route_short_name'] as String).trim()
            : ((routeDirection['route_long_name'] as String?)
                          ?.trim()
                          .isNotEmpty ==
                      true
                  ? (routeDirection['route_long_name'] as String).trim()
                  : routeId);
        final originRow = await txn.query(
          'gtfs_stops',
          columns: ['stop_name'],
          where: 'stop_id = ?',
          whereArgs: [times.first['stop_id']],
          limit: 1,
        );
        final destinationRow = await txn.query(
          'gtfs_stops',
          columns: ['stop_name'],
          where: 'stop_id = ?',
          whereArgs: [times.last['stop_id']],
          limit: 1,
        );
        final origin = originRow.isEmpty
            ? ''
            : '${originRow.first['stop_name'] ?? ''}';
        final fallbackDestination = destinationRow.isEmpty
            ? ''
            : '${destinationRow.first['stop_name'] ?? ''}';
        final headsign =
            (routeDirection['trip_headsign'] as String?)?.trim() ?? '';
        final destination = headsign.isNotEmpty
            ? headsign
            : fallbackDestination;
        await txn.insert('operator_routes', {
          'operator_route_id': operatorRouteId,
          'provider_code': 'uk',
          'route_number': routeNumber,
          'bound': '$directionId',
          'names': jsonEncode({'en': routeNumber}),
          'origin_text': jsonEncode({'en': origin}),
          'destination_text': jsonEncode({'en': destination}),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        final routeStopBatch = txn.batch();
        var sequence = 0;
        for (final time in times) {
          final stopId = time['stop_id'] as String;
          routeStopBatch.insert('route_stops', {
            'operator_route_id': operatorRouteId,
            'operator_stop_id': 'uk:$stopId',
            'stop_sequence': sequence++,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await routeStopBatch.commit(noResult: true);
      }
    });
  }

  /// Drops schedule records that became unrelated after area filtering.
  Future<void> removeUnreferencedGtfsRows() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.execute('''
        DELETE FROM gtfs_trips
        WHERE NOT EXISTS (
          SELECT 1 FROM gtfs_stop_times st WHERE st.trip_id = gtfs_trips.trip_id
        )
      ''');
      await txn.execute('''
        DELETE FROM gtfs_routes
        WHERE NOT EXISTS (
          SELECT 1 FROM gtfs_trips t WHERE t.route_id = gtfs_routes.route_id
        )
      ''');
      await txn.execute('''
        DELETE FROM gtfs_calendar
        WHERE NOT EXISTS (
          SELECT 1 FROM gtfs_trips t WHERE t.service_id = gtfs_calendar.service_id
        )
      ''');
      await txn.execute('''
        DELETE FROM gtfs_calendar_dates
        WHERE NOT EXISTS (
          SELECT 1 FROM gtfs_trips t
          WHERE t.service_id = gtfs_calendar_dates.service_id
        )
      ''');
    });
  }

  Future<void> upsertOperatorStops(List<TransportStop> stops) async {
    final batch = (await database).batch();
    for (final stop in stops) {
      batch.insert("operator_stops", {
        "operator_stop_id": stop.id,
        "provider_code": stop.providerCode,
        "names": jsonEncode(stop.names),
        "lat": stop.lat,
        "lng": stop.lng,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> upsertOperatorRoutes(List<TransportRoute> routes) async {
    final batch = (await database).batch();
    for (final route in routes) {
      batch.insert("operator_routes", {
        "operator_route_id": route.id,
        "provider_code": route.providerCode,
        "route_number": route.routeNumber,
        "bound": route.bound,
        "names": jsonEncode(route.names),
        "origin_text": jsonEncode(route.originText),
        "destination_text": jsonEncode(route.destinationText),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> upsertRouteStops(
    String operatorRouteId,
    List<String> operatorStopIds,
  ) async {
    final batch = (await database).batch();
    batch.delete(
      "route_stops",
      where: "operator_route_id = ?",
      whereArgs: [operatorRouteId],
    );
    for (var i = 0; i < operatorStopIds.length; i++) {
      batch.insert("route_stops", {
        "operator_route_id": operatorRouteId,
        "operator_stop_id": operatorStopIds[i],
        "stop_sequence": i,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    await batch.commit();
  }

  Future<void> interpolateMissingArrivalTimes() async {
    final db = await database;
    final tripIds = await db.rawQuery(
      "SELECT DISTINCT trip_id FROM gtfs_stop_times",
    );
    var batch = db.batch();
    var processedTrips = 0;

    for (final tripRow in tripIds) {
      final tripId = tripRow["trip_id"] as String;
      final stopTimes = await db.query(
        "gtfs_stop_times",
        where: "trip_id = ?",
        whereArgs: [tripId],
        orderBy: "stop_sequence ASC",
      );

      final knownIndices = <int>[];
      for (var i = 0; i < stopTimes.length; i++) {
        final time = stopTimes[i]["arrival_time"] as String?;
        if (time != null && time.isNotEmpty) {
          knownIndices.add(i);
        }
      }

      if (knownIndices.length < 2) continue;

      for (var i = 0; i < knownIndices.length - 1; i++) {
        final startIdx = knownIndices[i];
        final endIdx = knownIndices[i + 1];
        if (endIdx - startIdx <= 1) continue;

        final startSeconds = _timeToSeconds(
          stopTimes[startIdx]["arrival_time"] as String,
        );
        final endSeconds = _timeToSeconds(
          stopTimes[endIdx]["arrival_time"] as String,
        );
        final totalSteps = endIdx - startIdx;

        for (var j = startIdx + 1; j < endIdx; j++) {
          final fraction = (j - startIdx) / totalSteps;
          final interpolatedSeconds =
              startSeconds + ((endSeconds - startSeconds) * fraction).round();
          final interpolatedTime = _secondsToTime(interpolatedSeconds);

          batch.update(
            "gtfs_stop_times",
            {
              "arrival_time": interpolatedTime,
              "departure_time": interpolatedTime,
            },
            where: "trip_id = ? AND stop_sequence = ?",
            whereArgs: [tripId, stopTimes[j]["stop_sequence"]],
          );
        }
      }

      processedTrips++;
      if (processedTrips % 500 == 0) {
        await batch.commit(noResult: true);
        batch = db.batch(); // restarting commit batch lowers memory use and makes each batch process much faster
        // print("committed 500 interpolations (${processedTrips}/${tripIds.length})");
      }
    }
    await batch.commit(noResult: true);
  }

  Future<void> matchOperatorStopsToGtfs({
    double maxDistanceMeters = 150,
  }) async {
    final db = await database;
    final operatorRows = await db.query(
      "operator_stops",
      where: "lat IS NOT NULL AND lng IS NOT NULL",
    );
    final gtfsRows = await db.query("gtfs_stops");

    final nameIndex = <String, List<Map<String, dynamic>>>{};
    for (final gRow in gtfsRows) {
      final rawName = gRow["stop_name"] as String;
      for (final fragment in GtfsStop.extractNameFragments(rawName)) {
        final key = GtfsStop.normalizeForMatching(fragment);
        nameIndex.putIfAbsent(key, () => []).add(gRow);
      }
    }

    final batch = db.batch();
    final ambiguousMatches = <String>[];
    final noMatches = <String>[];

    for (final opRow in operatorRows) {
      final opStopId = opRow["operator_stop_id"] as String;
      final opLat = opRow["lat"] as double;
      final opLng = opRow["lng"] as double;
      final opName =
          (jsonDecode(opRow["names"] as String) as Map<String, dynamic>)["en"]
              as String? ??
          "";

      final normalizedOpName = GtfsStop.normalizeForMatching(opName);
      final nameCandidates = nameIndex[normalizedOpName] ?? [];

      String? bestGtfsId;
      double bestDistance;

      if (nameCandidates.length == 1) {
        bestGtfsId = nameCandidates.first["stop_id"] as String;
        bestDistance = haversineDistanceMeters(
          opLat,
          opLng,
          nameCandidates.first["stop_lat"] as double,
          nameCandidates.first["stop_lon"] as double,
        );
      } else if (nameCandidates.length > 1) {
        bestGtfsId = null;
        bestDistance = double.infinity;
        for (final candidate in nameCandidates) {
          final d = haversineDistanceMeters(
            opLat,
            opLng,
            candidate["stop_lat"] as double,
            candidate["stop_lon"] as double,
          );
          if (d < bestDistance) {
            bestDistance = d;
            bestGtfsId = candidate["stop_id"] as String;
          }
        }
        ambiguousMatches.add(
          "${opStopId} (name matched ${nameCandidates.length} GTFS stops, picked nearest)",
        );
      } else {
        bestGtfsId = null;
        bestDistance = double.infinity;
        for (final gRow in gtfsRows) {
          final d = haversineDistanceMeters(
            opLat,
            opLng,
            gRow["stop_lat"] as double,
            gRow["stop_lon"] as double,
          );
          if (d < bestDistance) {
            bestDistance = d;
            bestGtfsId = gRow["stop_id"] as String;
          }
        }
        noMatches.add(opStopId);
      }

      if (bestGtfsId == null || bestDistance > maxDistanceMeters) continue;

      batch.insert("stop_mapping", {
        "operator_stop_id": opStopId,
        "gtfs_stop_id": bestGtfsId,
        "match_confidence": bestDistance,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      // print("linked provider stop id ${opStopId} to gtfs stop id ${bestGtfsId}");
    }

    await batch.commit(noResult: true);

    if (ambiguousMatches.isNotEmpty) {
      print(
        "${ambiguousMatches.length} operator stops matched ambigiously (top 2 candidates within 20m): ${ambiguousMatches.join(", ")}",
      );
    }
    if (noMatches.isNotEmpty) {
      print(
        "${noMatches.length} matched by proximity only (no name match found): ${noMatches.join(", ")}",
      );
    }
  }

  Future<List<TransportRoute>> getOperatorRoutes(String providerCode) async {
    final rows = await (await database).query(
      "operator_routes",
      where: "provider_code = ?",
      whereArgs: [providerCode],
    );

    return rows
        .map(
          (row) => TransportRoute(
            id: row["operator_route_id"] as String,
            names: Map<String, String>.from(jsonDecode(row["names"] as String)),
            routeNumber: row["route_number"] as String,
            bound: row["bound"] as String,
            originText: Map<String, String>.from(
              jsonDecode(row["origin_text"] as String),
            ),
            destinationText: Map<String, String>.from(
              jsonDecode(row["destination_text"] as String),
            ),
            providerCode: row["provider_code"] as String,
          ),
        )
        .toList();
  }

  Future<bool> hasOperatorStops(String providerCode) async {
    final rows = await (await database).query(
      'operator_stops',
      columns: ['operator_stop_id'],
      where: 'provider_code = ?',
      whereArgs: [providerCode],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<bool> hasOperatorStop(String operatorStopId) async {
    final rows = await (await database).query(
      'operator_stops',
      columns: ['operator_stop_id'],
      where: 'operator_stop_id = ?',
      whereArgs: [operatorStopId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<bool> hasRouteStops(String operatorRouteId) async {
    final rows = await (await database).query(
      'route_stops',
      columns: ['operator_route_id'],
      where: 'operator_route_id = ?',
      whereArgs: [operatorRouteId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<bool> hasOperatorRouteStops(String providerCode) async {
    final rows = await (await database).rawQuery(
      '''
      SELECT 1
      FROM route_stops rs
      INNER JOIN operator_routes r
        ON r.operator_route_id = rs.operator_route_id
      WHERE r.provider_code = ?
      LIMIT 1
      ''',
      [providerCode],
    );
    return rows.isNotEmpty;
  }

  Future<bool> hasUsableGtfsData() async {
    final rows = await (await database).rawQuery('''
      SELECT
        (SELECT COUNT(*) FROM gtfs_routes) AS routes,
        (SELECT COUNT(*) FROM gtfs_trips) AS trips,
        ((SELECT COUNT(*) FROM gtfs_calendar) +
         (SELECT COUNT(*) FROM gtfs_calendar_dates)) AS calendar,
        (SELECT COUNT(*) FROM gtfs_stops) AS stops,
        (SELECT COUNT(*) FROM gtfs_stop_times) AS stop_times
    ''');
    final counts = rows.single;
    return counts.values.every((value) => value is int && value > 0);
  }

  Future<List<String>> getOperatorStopIdsForProvider(
    String providerCode,
  ) async {
    final rows = await (await database).rawQuery(
      '''
      SELECT DISTINCT rs.operator_stop_id
      FROM route_stops rs
      INNER JOIN operator_routes r
        ON r.operator_route_id = rs.operator_route_id
      WHERE r.provider_code = ?
      ''',
      [providerCode],
    );
    return rows.map((row) => row['operator_stop_id'] as String).toList();
  }

  Future<List<ScheduledDeparture>> getUpcomingDepartures(
    String stopId, {
    int limit = 5,
    List<String>? routeIds,
    int? directionId,
  }) async {
    if (routeIds != null && routeIds.isEmpty) return const [];
    final db = await database;
    final now = localeConfigs[locale]!.nowInLocale();

    final weekDays = [
      "monday",
      "tuesday",
      "wednesday",
      "thursday",
      "friday",
      "saturday",
      "sunday",
    ];
    final currentDayColumn = weekDays[now.weekday - 1];

    final currentServiceTime =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    final dateStr =
        "${now.year}${now.month.toString().padLeft(2, "0")}${now.day.toString().padLeft(2, "0")}";
    final routeFilter = routeIds == null
        ? ''
        : 'AND r.route_id IN (${List.filled(routeIds.length, '?').join(',')})';
    final directionFilter = directionId == null
        ? ''
        : 'AND COALESCE(t.direction_id, 0) = ?';

    final List<Map<String, dynamic>> rows = await db.rawQuery(
      '''
    SELECT r.route_id, r.route_short_name, r.route_long_name,
           st.arrival_time, t.direction_id
    FROM gtfs_stop_times st
    INNER JOIN gtfs_trips t ON st.trip_id = t.trip_id
    INNER JOIN gtfs_routes r ON t.route_id = r.route_id
    WHERE st.stop_id = ?
      AND CAST(substr(st.arrival_time, 1, 2) AS INTEGER) * 3600
          + CAST(substr(st.arrival_time, 4, 2) AS INTEGER) * 60
          + CAST(substr(st.arrival_time, 7, 2) AS INTEGER)
          > CAST(substr(?, 1, 2) AS INTEGER) * 3600
          + CAST(substr(?, 4, 2) AS INTEGER) * 60
          + CAST(substr(?, 7, 2) AS INTEGER)
      AND (
        EXISTS (
          SELECT 1 FROM gtfs_calendar c
          WHERE c.service_id = t.service_id
            AND c.$currentDayColumn = 1
            AND c.start_date <= ?
            AND c.end_date >= ?
        )
        OR EXISTS (
          SELECT 1 FROM gtfs_calendar_dates cd
          WHERE cd.service_id = t.service_id
            AND cd.date = ?
            AND cd.exception_type = 1
        )
      )
      AND NOT EXISTS (
        SELECT 1 FROM gtfs_calendar_dates cd
        WHERE cd.service_id = t.service_id
          AND cd.date = ?
        AND cd.exception_type = 2
      )
      $routeFilter
      $directionFilter
    ORDER BY
      CAST(substr(st.arrival_time, 1, 2) AS INTEGER) * 3600
        + CAST(substr(st.arrival_time, 4, 2) AS INTEGER) * 60
        + CAST(substr(st.arrival_time, 7, 2) AS INTEGER) ASC
    LIMIT ?
    ''',
      [
        stopId,
        currentServiceTime,
        currentServiceTime,
        currentServiceTime,
        dateStr,
        dateStr,
        dateStr,
        dateStr,
        ...?routeIds,
        if (directionId != null) directionId,
        limit,
      ],
    );

    return rows
        .map(
          (row) => ScheduledDeparture(
            routeShortName:
                (row["route_short_name"] as String?)?.isNotEmpty == true
                ? row["route_short_name"] as String
                : ((row['route_long_name'] as String?)?.isNotEmpty == true
                      ? row['route_long_name'] as String
                      : row['route_id'] as String),
            routeId: row['route_id'] as String,
            arrivalTime: row["arrival_time"] as String,
            directionId: row["direction_id"] as int?,
            locale: locale,
          ),
        )
        .toList();
  }

  Future<List<GtfsStop>> getAllGtfsStops({String? languageCode}) async {
    // query to only include stops with mapped routes
    final rows = await (await database).rawQuery('''
    SELECT DISTINCT s.*
    FROM gtfs_stops s
    INNER JOIN stop_mapping sm on sm.gtfs_stop_id = s.stop_id
    ''');
    final operatorNameRows = await (await database).rawQuery('''
    SELECT sm.gtfs_stop_id, os.names
    FROM stop_mapping sm
    INNER JOIN operator_stops os ON os.operator_stop_id = sm.operator_stop_id
    ''');
    final namesByGtfsStop = <String, List<Map<String, String>>>{};
    for (final operatorRow in operatorNameRows) {
      final stopId = operatorRow['gtfs_stop_id'] as String;
      final rawNames =
          jsonDecode(operatorRow['names'] as String) as Map<String, dynamic>;
      namesByGtfsStop
          .putIfAbsent(stopId, () => [])
          .add(rawNames.map((key, value) => MapEntry(key, value as String)));
    }
    final selectedLanguage = languageCode ?? AppStrings.languageCode;
    return rows.map((row) {
      final stopId = row['stop_id'] as String;
      final fallbackName = GtfsStop.cleanStopName(row['stop_name'] as String);
      final operatorNames =
          namesByGtfsStop[stopId] ?? const <Map<String, String>>[];
      return GtfsStop(
        id: stopId,
        name: GtfsStop.localizedNameFromOperators(
          operatorNames,
          selectedLanguage,
          fallbackName: fallbackName,
        ),
        lat: row['stop_lat'] as double,
        lng: row['stop_lon'] as double,
        operatorNames: operatorNames,
        localeCode: locale,
      );
    }).toList();
  }

  Future<List<TransportRoute>> getRoutesForGtfsStop(String gtfsStopId) async {
    // todo check query on circular routes
    final rows = await (await database).rawQuery(
      '''
    SELECT DISTINCT r.*
    FROM operator_routes r
    INNER JOIN route_stops rs ON rs.operator_route_id = r.operator_route_id
    INNER JOIN stop_mapping sm ON sm.operator_stop_id = rs.operator_stop_id
    WHERE sm.gtfs_stop_id = ? AND rs.stop_sequence < (
      SELECT MAX(rs2.stop_sequence)
      FROM route_stops rs2
      WHERE rs2.operator_route_id = rs.operator_route_id
    )
    ''',
      [gtfsStopId],
    );

    return rows
        .map(
          (row) => TransportRoute(
            id: row["operator_route_id"] as String,
            names: Map<String, String>.from(jsonDecode(row["names"] as String)),
            routeNumber: row["route_number"] as String,
            bound: row["bound"] as String,
            originText: Map<String, String>.from(
              jsonDecode(row["origin_text"] as String),
            ),
            destinationText: Map<String, String>.from(
              jsonDecode(row["destination_text"] as String),
            ),
            providerCode: row["provider_code"] as String,
          ),
        )
        .toList();
  }

  Future<List<TransportRoute>> getRoutesForOperatorStop(
    String operatorStopId,
  ) async {
    final rows = await (await database).rawQuery(
      '''
      SELECT DISTINCT r.*
      FROM operator_routes r
      INNER JOIN route_stops rs ON rs.operator_route_id = r.operator_route_id
      WHERE rs.operator_stop_id = ?
        AND rs.stop_sequence < (
          SELECT MAX(rs2.stop_sequence)
          FROM route_stops rs2
          WHERE rs2.operator_route_id = rs.operator_route_id
        )
    ''',
      [operatorStopId],
    );
    return rows
        .map(
          (row) => TransportRoute(
            id: row['operator_route_id'] as String,
            names: Map<String, String>.from(jsonDecode(row['names'] as String)),
            routeNumber: row['route_number'] as String,
            bound: row['bound'] as String? ?? '',
            originText: Map<String, String>.from(
              jsonDecode(row['origin_text'] as String),
            ),
            destinationText: Map<String, String>.from(
              jsonDecode(row['destination_text'] as String),
            ),
            providerCode: row['provider_code'] as String,
          ),
        )
        .toList();
  }

  Future<List<String>> getOperatorStopIds(
    String gtfsStopId, {
    String? providerCode,
  }) async {
    final where = providerCode != null
        ? "sm.gtfs_stop_id = ? AND os.provider_code = ?"
        : "sm.gtfs_stop_id = ?";
    final whereArgs = providerCode != null
        ? [gtfsStopId, providerCode]
        : [gtfsStopId];

    final rows = await (await database).rawQuery('''
    SELECT sm.operator_stop_id
    FROM stop_mapping sm
    INNER JOIN operator_stops os ON os.operator_stop_id = sm.operator_stop_id
    WHERE $where
    ''', whereArgs);

    return rows.map((r) => r["operator_stop_id"] as String).toList();
  }

  Future<String?> getGtfsStopIdForOperatorStop(String operatorStopId) async {
    final rows = await (await database).query(
      'stop_mapping',
      columns: ['gtfs_stop_id'],
      where: 'operator_stop_id = ?',
      whereArgs: [operatorStopId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['gtfs_stop_id'] as String?;
  }

  /// Resolves a selected route's operator stop once while creating the alarm.
  /// The resulting API URL is stored on the alarm for later push handling.
  Future<String?> getOperatorStopIdForRouteAtGtfsStop({
    required String operatorRouteId,
    required String gtfsStopId,
    String? providerCode,
  }) async {
    final rows = await (await database).rawQuery(
      '''
    SELECT rs.operator_stop_id
    FROM route_stops rs
    INNER JOIN stop_mapping sm ON sm.operator_stop_id = rs.operator_stop_id
    WHERE rs.operator_route_id = ? AND sm.gtfs_stop_id = ?
      AND (? IS NULL OR EXISTS (
        SELECT 1 FROM operator_stops os
        WHERE os.operator_stop_id = rs.operator_stop_id
          AND os.provider_code = ?
      ))
    ORDER BY rs.stop_sequence
    LIMIT 1
    ''',
      [operatorRouteId, gtfsStopId, providerCode, providerCode],
    );

    return rows.isEmpty ? null : rows.first["operator_stop_id"] as String?;
  }

  Future<GtfsStop?> getGtfsStopById(
    String stopId, {
    String? languageCode,
  }) async {
    final rows = await (await database).query(
      "gtfs_stops",
      where: "stop_id = ?",
      whereArgs: [stopId],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final operatorNameRows = await (await database).rawQuery(
      '''
    SELECT os.names
    FROM stop_mapping sm
    INNER JOIN operator_stops os ON os.operator_stop_id = sm.operator_stop_id
    WHERE sm.gtfs_stop_id = ?
    ''',
      [stopId],
    );
    final operatorNames = operatorNameRows.map((operatorRow) {
      final rawNames =
          jsonDecode(operatorRow['names'] as String) as Map<String, dynamic>;
      return rawNames.map((key, value) => MapEntry(key, value as String));
    }).toList();
    final fallbackName = GtfsStop.cleanStopName(row['stop_name'] as String);
    return GtfsStop(
      id: row["stop_id"] as String,
      name: GtfsStop.localizedNameFromOperators(
        operatorNames,
        languageCode ?? AppStrings.languageCode,
        fallbackName: fallbackName,
      ),
      lat: row["stop_lat"] as double,
      lng: row["stop_lon"] as double,
      operatorNames: operatorNames,
      localeCode: locale,
    );
  }

  Future<List<String>> getRouteNumbersForOperatorStop(
    String operatorStopId,
  ) async {
    final rows = await (await database).rawQuery(
      '''
    SELECT r.route_number
    FROM route_stops rs
    INNER JOIN operator_routes r ON r.operator_route_id = rs.operator_route_id
    WHERE rs.operator_stop_id = ?
    ''',
      [operatorStopId],
    );
    return rows.map((row) => row["route_number"] as String).toList();
  }

  Future<void> clearAllTables() async {
    final db = await database;
    await db.transaction(((txn) async {
      await txn.delete("gtfs_routes");
      await txn.delete("gtfs_trips");
      await txn.delete("gtfs_calendar");
      await txn.delete("gtfs_calendar_dates");
      await txn.delete("gtfs_stop_times");
    }));
  }

  Future<void> resetDatabase() async {
    if (_databases.containsKey(locale) && _databases[locale]!.isOpen) {
      await _databases[locale]!.close();
    }
    _databases.remove(locale);
    final dir = await AppGroupStorage.directory;
    final databaseDir = Directory('${dir.path}/gtfs');
    for (final entity
        in databaseDir.existsSync()
            ? databaseDir.listSync()
            : const <FileSystemEntity>[]) {
      if (entity is File &&
          (entity.path.endsWith('/$locale.db') ||
              entity.path.contains('/$locale.db.'))) {
        await entity.delete();
      }
    }
    final legacyFile = File('${dir.path}/gtfs/gtfs/$locale.db');
    if (await legacyFile.exists()) await legacyFile.delete();
    final legacyBackup = File('${dir.path}/gtfs/gtfs/$locale.db.backup');
    if (await legacyBackup.exists()) {
      await legacyBackup.delete();
    }
  }

  int _timeToSeconds(String hhmmss) {
    final parts = hhmmss.split(":");
    return int.parse(parts[0]) * 3600 +
        int.parse(parts[1]) * 60 +
        int.parse(parts[2]);
  }

  String _secondsToTime(int totalSeconds) {
    return "${(totalSeconds ~/ 3600).toString().padLeft(2, "0")}:${((totalSeconds % 3600) ~/ 60).toString().padLeft(2, "0")}:${(totalSeconds % 60).toString().padLeft(2, "0")}";
  }
}
