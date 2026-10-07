import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:transport_alarm/locale_registry.dart';
import 'package:transport_alarm/models/scheduled_departure.dart';
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
      databaseFile = File(_explicitDatabasePath!);
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
    Future<void> Function(GtfsDatabase stagingDatabase) populate,
  ) async {
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
      await _copyOperatorData(currentDb, await stagingDb.database);
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

  Future<void> _copyOperatorData(Database source, Database target) async {
    final validStopRows = await target.query(
      'gtfs_stops',
      columns: ['stop_id'],
    );
    final validStopIds = validStopRows
        .map((row) => row['stop_id'] as String)
        .toSet();
    await target.transaction((txn) async {
      for (final table in [
        'operator_stops',
        'operator_routes',
        'route_stops',
      ]) {
        final rows = await source.query(table);
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
      final mappings = await source.query('stop_mapping');
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
      'gtfs_calendar',
      'gtfs_stops',
      'gtfs_stop_times',
    ]) {
      final result = await db.rawQuery('SELECT COUNT(*) AS count FROM $table');
      if ((result.first['count'] as int?) == null ||
          (result.first['count'] as int) == 0) {
        throw StateError('Refusing to install an empty GTFS table: $table');
      }
    }
  }

  Future<void> close() async {
    final db = _databases.remove(_cacheKey);
    if (db != null && db.isOpen) await db.close();
  }

  Future<Database> _initDB(String filePath) async {
    return await openDatabase(
      filePath,
      version: 2,
      onCreate: _createDB,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createCalendarDatesTable(db);
          await _createAgenciesTable(db);
          await db.execute(
            "ALTER TABLE gtfs_routes ADD COLUMN agency_id TEXT NOT NULL DEFAULT ''",
          );
          await db.execute(
            "ALTER TABLE gtfs_routes ADD COLUMN agency_name TEXT NOT NULL DEFAULT ''",
          );
        }
      },
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''CREATE TABLE gtfs_routes (
    route_id TEXT PRIMARY KEY, 
    route_short_name TEXT NOT NULL,
    agency_id TEXT NOT NULL DEFAULT '',
    agency_name TEXT NOT NULL DEFAULT ''
    )''');
    await _createAgenciesTable(db);

    await db.execute('''CREATE TABLE gtfs_trips (
    trip_id TEXT PRIMARY KEY, 
    route_id TEXT NOT NULL, 
    service_id TEXT NOT NULL, 
    direction_id INTEGER
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
    await _createCalendarDatesTable(db);

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
    stop_lon REAL NOT NULL
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

  Future<void> _createCalendarDatesTable(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE gtfs_calendar_dates (
      service_id TEXT NOT NULL,
      date TEXT NOT NULL,
      exception_type INTEGER NOT NULL,
      PRIMARY KEY (service_id, date)
    )''');
  }

  Future<void> _createAgenciesTable(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE gtfs_agencies (
      agency_id TEXT PRIMARY KEY,
      agency_name TEXT NOT NULL
    )''');
  }

  String _val(List<dynamic> row, int index) =>
      row.length > index ? row[index].toString() : "";

  Future<void> batchInsertRoutes(List<dynamic> header, List<List<dynamic>> rows) async {
    int columnIndex(String name, {bool required = true}) {
      final index = header.indexOf(name);
      if (index < 0 && required) {
        throw FormatException('GTFS routes.txt is missing the $name column.');
      }
      return index;
    }

    final routeIdIndex = columnIndex('route_id');
    final routeNameIndex = columnIndex('route_short_name');

    String value(List<dynamic> row, int index) =>
        index >= 0 && row.length > index ? row[index].toString() : '';

    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var row in rows) {
        batch.insert("gtfs_routes", {
          "route_id": value(row, routeIdIndex),
          "route_short_name": value(row, routeNameIndex),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> batchInsertAgencies(List<dynamic> header, List<List<dynamic>> rows) async {
    int columnIndex(String name, {bool required = true}) {
      final index = header.indexOf(name);
      if (index < 0 && required) {
        throw FormatException('GTFS agency.txt is missing the $name column.');
      }
      return index;
    }

    final agencyIdIndex = columnIndex('agency_id');
    final agencyNameIndex = columnIndex('agency_name');

    String value(List<dynamic> row, int index) =>
        index >= 0 && row.length > index ? row[index].toString() : '';

    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final row in rows) {
        batch.insert('gtfs_agencies', {
          'agency_id': value(row, agencyIdIndex),
          'agency_name': value(row, agencyNameIndex),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> batchInsertTrips(List<dynamic> header, List<List<dynamic>> rows) async {
    int columnIndex(String name, {bool required = true}) {
      final index = header.indexOf(name);
      if (index < 0 && required) {
        throw FormatException('GTFS trips.txt is missing the $name column.');
      }
      return index;
    }

    final routeIdIndex = columnIndex('route_id');
    final serviceIdIndex = columnIndex('service_id');
    final tripIdIndex = columnIndex('trip_id');
    final directionIdIndex = columnIndex('direction_id', required: false);

    String value(List<dynamic> row, int index) =>
        index >= 0 && row.length > index ? row[index].toString() : '';

    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var row in rows) {
        batch.insert("gtfs_trips", {
          "route_id": value(row, routeIdIndex),
          "service_id": value(row, serviceIdIndex),
          "trip_id": value(row, tripIdIndex),
          "direction_id": int.tryParse(value(row, directionIdIndex)) ?? 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> batchInsertCalendar(List<dynamic> header, List<List<dynamic>> rows) async {
    int columnIndex(String name, {bool required = true}) {
      final index = header.indexOf(name);
      if (index < 0 && required) {
        throw FormatException('GTFS calendar.txt is missing the $name column.');
      }
      return index;
    }

    final serviceIdIndex = columnIndex('service_id');
    final monIndex = columnIndex('monday', required: false);
    final tueIndex = columnIndex('tuesday', required: false);
    final wedIndex = columnIndex('wednesday', required: false);
    final thuIndex = columnIndex('thursday', required: false);
    final friIndex = columnIndex('friday', required: false);
    final satIndex = columnIndex('saturday', required: false);
    final sunIndex = columnIndex('sunday', required: false);
    final startDateIndex = columnIndex('start_date');
    final endDateIndex = columnIndex('end_date');

    String value(List<dynamic> row, int index) =>
        index >= 0 && row.length > index ? row[index].toString() : '';

    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var row in rows) {
        batch.insert("gtfs_calendar", {
          "service_id": value(row, serviceIdIndex),
          "monday": int.tryParse(value(row, monIndex)) ?? 0,
          "tuesday": int.tryParse(value(row, tueIndex)) ?? 0,
          "wednesday": int.tryParse(value(row, wedIndex)) ?? 0,
          "thursday": int.tryParse(value(row, thuIndex)) ?? 0,
          "friday": int.tryParse(value(row, friIndex)) ?? 0,
          "saturday": int.tryParse(value(row, satIndex)) ?? 0,
          "sunday": int.tryParse(value(row, sunIndex)) ?? 0,
          "start_date": value(row, startDateIndex),
          "end_date": value(row, endDateIndex),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> batchInsertCalendarDates(List<dynamic> header, List<List<dynamic>> rows) async {
    int columnIndex(String name, {bool required = true}) {
      final index = header.indexOf(name);
      if (index < 0 && required) {
        throw FormatException('GTFS calendar_dates.txt is missing the $name column.');
      }
      return index;
    }

    final serviceIdIndex = columnIndex('service_id');
    final dateIndex = columnIndex('date');
    final exceptionTypeIndex = columnIndex('exception_type', required: false);

    String value(List<dynamic> row, int index) =>
        index >= 0 && row.length > index ? row[index].toString() : '';

    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final row in rows) {
        batch.insert('gtfs_calendar_dates', {
          'service_id': value(row, serviceIdIndex),
          'date': value(row, dateIndex),
          'exception_type': int.tryParse(value(row, exceptionTypeIndex)) ?? 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> batchInsertStops(
    List<dynamic> header,
    List<List<dynamic>> rows,
  ) async {
    int columnIndex(String name, {bool required = true}) {
      final index = header.indexOf(name);
      if (index < 0 && required) {
        throw FormatException('GTFS stops.txt is missing the $name column.');
      }
      return index;
    }

    final stopIdIndex = columnIndex('stop_id');
    final stopNameIndex = columnIndex('stop_name');
    final stopLatIndex = columnIndex('stop_lat', required: false);
    final stopLonIndex = columnIndex('stop_lon', required: false);

    String value(List<dynamic> row, int index) =>
        index >= 0 && row.length > index ? row[index].toString() : '';

    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var row in rows) {
        batch.insert("gtfs_stops", {
          "stop_id": value(row, stopIdIndex),
          "stop_name": value(row, stopNameIndex),
          "stop_lat": double.tryParse(value(row, stopLatIndex)) ?? 0,
          "stop_lon": double.tryParse(value(row, stopLonIndex)) ?? 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> batchInsertStopTimes(List<dynamic> header, List<List<dynamic>> rows) async {

    int columnIndex(String name, {bool required = true}) {
      final index = header.indexOf(name);
      if (index < 0 && required) {
        throw FormatException('GTFS stop_times.txt is missing the $name column.');
      }
      return index;
    }

    final tripIdIndex = columnIndex('trip_id');
    final arrivalTimeIndex = columnIndex('arrival_time');
    final departureTimeIndex = columnIndex('departure_time');
    final stopIdIndex = columnIndex('stop_id');
    final stopSeqIndex = columnIndex('stop_sequence', required: false);

    String value(List<dynamic> row, int index) =>
        index >= 0 && row.length > index ? row[index].toString() : '';

    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var row in rows) {
        batch.insert("gtfs_stop_times", {
          "trip_id": value(row, tripIdIndex),
          "arrival_time": value(row, arrivalTimeIndex),
          "departure_time": value(row, departureTimeIndex),
          "stop_id": value(row, stopIdIndex),
          "stop_sequence": int.tryParse(value(row, stopSeqIndex)) ?? 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
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
            locale: locale,
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
        (SELECT COUNT(*) FROM gtfs_calendar) AS calendar,
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
  }) async {
    final db = await database;
    final now = LocaleRegistry.getLocale(locale).config.nowInLocale();

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

    final timeStr =
        "${now.hour.toString().padLeft(2, "0")}:${now.minute.toString().padLeft(2, "0")}:${now.second.toString().padLeft(2, "0")}";
    final dateStr =
        "${now.year}${now.month.toString().padLeft(2, "0")}${now.day.toString().padLeft(2, "0")}";

    final List<Map<String, dynamic>> rows = await db.rawQuery(
      '''
    SELECT r.route_short_name, st.arrival_time, t.direction_id
    from gtfs_stop_times st
    INNER JOIN gtfs_trips t ON st.trip_id = t.trip_id
    INNER JOIN gtfs_routes r ON t.route_id = r.route_id
    INNER JOIN gtfs_calendar c ON t.service_id = c.service_id
    WHERE st.stop_id = ?
      AND st.arrival_time > ?
      AND c.$currentDayColumn = 1
      AND c.start_date <= ?
      AND c.end_date >= ?
    ORDER BY st.arrival_time ASC
    LIMIT ?
    ''',
      [stopId, timeStr, dateStr, dateStr, limit],
    );

    return rows
        .map(
          (row) => ScheduledDeparture(
            routeShortName: row["route_short_name"] as String,
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
        locale: locale,
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
            locale: locale,
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

  /// Resolves a selected route's operator stop once while creating the alarm.
  /// The resulting API URL is stored on the alarm for later push handling.
  Future<String?> getOperatorStopIdForRouteAtGtfsStop({
    required String operatorRouteId,
    required String gtfsStopId,
  }) async {
    final rows = await (await database).rawQuery(
      '''
    SELECT rs.operator_stop_id
    FROM route_stops rs
    INNER JOIN stop_mapping sm ON sm.operator_stop_id = rs.operator_stop_id
    WHERE rs.operator_route_id = ? AND sm.gtfs_stop_id = ?
    ORDER BY rs.stop_sequence
    LIMIT 1
    ''',
      [operatorRouteId, gtfsStopId],
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
      locale: locale,
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

  /// Removes UK feed records that are outside the selected ATCO areas and
  /// creates the operator-facing records consumed by the app's existing UI.
  Future<void> materializeGbOperatorData() async {
    final db = await database;
    await db.transaction((txn) async {
      final stops = await txn.query('gtfs_stops');
      var stopBatch = txn.batch();
      var processedStops = 0;
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

        processedStops++;
        if (processedStops % 500 == 0) {
          await stopBatch.commit(noResult: true);
          stopBatch = txn.batch(); // restarting commit batch lowers memory use and makes each batch process much faster
          // print("committed 500 interpolations (${processedTrips}/${tripIds.length})");
        }
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
        var routeStopBatch = txn.batch();
        var sequence = 0;
        var processedRouteStops = 0;
        for (final time in times) {
          final stopId = time['stop_id'] as String;
          routeStopBatch.insert('route_stops', {
            'operator_route_id': operatorRouteId,
            'operator_stop_id': 'uk:$stopId',
            'stop_sequence': sequence++,
          }, conflictAlgorithm: ConflictAlgorithm.replace);

          processedRouteStops++;
          if (processedRouteStops % 500 == 0) {
            await routeStopBatch.commit(noResult: true);
            routeStopBatch = txn.batch(); // restarting commit batch lowers memory use and makes each batch process much faster
            // print("committed 500 interpolations (${processedTrips}/${tripIds.length})");
          }
        }
        await routeStopBatch.commit(noResult: true);
      }
    });
  }

  Future<void> clearAllTables() async {
    final db = await database;
    await db.transaction(((txn) async {
      await txn.delete("gtfs_routes");
      await txn.delete("gtfs_trips");
      await txn.delete("gtfs_calendar");
      await txn.delete("gtfs_stop_times");
    }));
  }

  Future<void> resetDatabase() async {
    if (_databases.containsKey(locale) && _databases[locale]!.isOpen) {
      await _databases[locale]!.close();
    }
    _databases.remove(locale);
    final dir = await AppGroupStorage.directory;
    final file = File("${dir.path}/gtfs/$locale.db");
    if (await file.exists()) {
      await file.delete();
    }
    final legacyFile = File('${dir.path}/gtfs/gtfs/$locale.db');
    if (await legacyFile.exists()) {
      await legacyFile.delete();
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
