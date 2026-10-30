import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:transport_alarm/locale_registry.dart';
import 'package:transport_alarm/transit/cancellation.dart';
import 'package:transport_alarm/models/scheduled_departure.dart';
import 'package:transport_alarm/services/geo_utils.dart';
import 'package:transport_alarm/transit/models/transport_stop.dart';
import 'package:transport_alarm/transit/models/gtfs_stop.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:sqflite/sqflite.dart';

import '../models/transport_route.dart';

/// Thrown when a region's live database is opened but its file doesn't
/// exist, as when the region was turned off and its data deleted. Lookups
/// never recreate the file; only an import does.
class LocaleDataMissingException implements Exception {
  const LocaleDataMissingException(this.locale);

  final String locale;

  @override
  String toString() => 'No transit data for $locale';
}

class GtfsDatabase {
  static final Map<String, GtfsDatabase> _instances = {};
  static final Map<String, Database> _databases = {};
  static final Map<String, Future<void>> _replacementBarriers = {};
  static final Map<String, Future<void>> _refreshTails = {};
  static final Map<String, String> _deferredStagingPaths = {};
  // A connection being opened, keyed like [_databases], so callers that ask
  // for it at the same time share one connection instead of each opening
  // their own.
  static final Map<String, Future<Database>> _opening = {};
  // Each install writes a new value to gtfs/<locale>.generation. An isolate
  // that didn't do the install, such as Android's background alarm isolate,
  // sees the value change and reopens, instead of reading the replaced file
  // through its old connection for as long as it lives.
  static final Map<String, String?> _openedGenerations = {};
  static final Map<String, DateTime> _generationCheckedAt = {};
  static const _generationCheckInterval = Duration(seconds: 15);
  final String locale;
  final String? _explicitDatabasePath;
  // Shared per stop so concurrent callers (route pills, arrivals, stop sheet)
  // run the routes query once. Cleared whenever the active database changes.
  final Map<String, Future<List<TransportRoute>>> _routesForStopCache = {};

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
    final cached = _databases[_cacheKey];
    if (cached != null && cached.isOpen) {
      if (_explicitDatabasePath != null || !await _replacedElsewhere()) {
        return cached;
      }
      _databases.remove(_cacheKey);
      _contentsChanged();
      // Queries already running on the old connection get time to finish.
      unawaited(Future<void>.delayed(const Duration(seconds: 30), cached.close));
    }
    final key = _cacheKey;
    return _opening[key] ??= _open().whenComplete(() => _opening.remove(key));
  }

  /// Opens this instance's file and caches the connection, for [database].
  Future<Database> _open() async {
    late final File databaseFile;
    if (_explicitDatabasePath != null) {
      databaseFile = File(_explicitDatabasePath);
      await databaseFile.parent.create(recursive: true);
    } else {
      final dir = Directory('${(await AppGroupStorage.directory).path}/gtfs');
      await dir.create(recursive: true);
      databaseFile = File('${dir.path}/$locale.db');
      final backupFile = File('${dir.path}/$locale.db.backup');
      // Older versions swapped files in two renames, through this backup;
      // recover one left by a process that stopped between them.
      if (!await databaseFile.exists() && await backupFile.exists()) {
        await backupFile.rename(databaseFile.path);
      }
      final legacyFile = File('${dir.path}/gtfs/$locale.db');
      if (!await databaseFile.exists() && await legacyFile.exists()) {
        await legacyFile.copy(databaseFile.path);
      }
      // Opening would create an empty file, for a region that's most likely
      // just been turned off.
      if (!await databaseFile.exists()) throw LocaleDataMissingException(locale);
    }
    if (_explicitDatabasePath == null) {
      _openedGenerations[locale] = await _readGeneration();
      _generationCheckedAt[locale] = DateTime.now();
    }
    final db = await _initDB(databaseFile.path);
    _databases[_cacheKey] = db;
    return db;
  }

  File _generationFile(String gtfsDirectory) =>
      File('$gtfsDirectory/$locale.generation');

  Future<String?> _readGeneration() async {
    try {
      final file = _generationFile('${(await AppGroupStorage.directory).path}/gtfs');
      return await file.exists() ? await file.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  /// Whether another isolate has installed a new database since this one
  /// opened it. Checked at most every [_generationCheckInterval].
  Future<bool> _replacedElsewhere() async {
    final now = DateTime.now();
    final lastCheck = _generationCheckedAt[locale];
    if (lastCheck != null && now.difference(lastCheck) < _generationCheckInterval) {
      return false;
    }
    _generationCheckedAt[locale] = now;
    return await _readGeneration() != _openedGenerations[locale];
  }

  /// Builds a replacement in a separate SQLite file and installs it only after
  /// the caller has populated and validated the complete snapshot.
  Future<void> refreshAtomically(
    Future<void> Function(GtfsDatabase stagingDatabase) populate, {
    bool deferCommit = false,
    CancellationToken? cancelToken,
  }) async {
    final previousRefresh = _refreshTails[locale] ?? Future<void>.value();
    final refreshFinished = Completer<void>();
    _refreshTails[locale] = refreshFinished.future;
    await previousRefresh;

    Completer<void>? barrier;
    GtfsDatabase? stagingDb;
    File? stagingFile;
    var preserveStagingFile = false;
    var populateSucceeded = false;
    var swapping = false;
    try {
      // A first import has no live file to carry operator data over from.
      Database? currentDb;
      try {
        currentDb = await database;
      } on LocaleDataMissingException {
        currentDb = null;
      }
      final appDir = await AppGroupStorage.directory;
      final dbDir = Directory('${appDir.path}/gtfs');
      await dbDir.create(recursive: true);
      final activeFile = File('${dbDir.path}/$locale.db');
      final deferredPath = _deferredStagingPaths[locale];
      stagingFile = deferredPath != null && await File(deferredPath).exists()
          ? File(deferredPath)
          : File(
              '${dbDir.path}/$locale.db.staging.${DateTime.now().microsecondsSinceEpoch}',
            );
      _deferredStagingPaths[locale] = stagingFile.path;
      stagingDb = GtfsDatabase._atPath(locale, stagingFile.path);

      // Create the staging schema for the first archive, or reopen the partial
      // snapshot left by an earlier archive. Carry operator data forward only
      // after the complete timetable snapshot has been populated.
      // Bulk-load settings for the staging file only. It's discarded if the
      // import fails and validated before it's installed, so it doesn't need
      // the journal and syncing that protect the live database; skipping them
      // makes the import many times faster and far lighter on storage. They
      // apply to this connection only: the installed file reopens with the
      // defaults.
      final stagingConnection = await stagingDb.database;
      await stagingConnection.rawQuery('PRAGMA journal_mode=OFF');
      await stagingConnection.execute('PRAGMA synchronous=OFF');
      await stagingConnection.execute('PRAGMA cache_size=-32768');
      await populate(stagingDb);
      populateSucceeded = true;

      // Keep this partial snapshot available for the next regional archive.
      // The active database is replaced only when the final region is ready.
      if (deferCommit) {
        preserveStagingFile = true;
        return;
      }

      // From here the new snapshot is copied in and swapped for the active
      // file, which must finish once started.
      cancelToken?.beginUncancellable();
      swapping = true;

      // Pause new database lookups while the operator data is copied and the
      // active file is swapped, so nothing writes to the active file after
      // its operator data was copied. The existing timetable remains
      // readable while the new snapshot is being downloaded and built.
      //
      // Nothing from here until the barrier is released may call the live
      // [database] getter (directly or through another method of this
      // instance): it waits on this barrier, so it would wait forever. Use
      // currentDb, the staging connection, or the installed one instead.
      barrier = Completer<void>();
      _replacementBarriers[locale] = barrier.future;
      if (currentDb != null) {
        await _copyOperatorData(currentDb, await stagingDb.database);
      }
      await _validateSnapshot(await stagingDb.database);
      await stagingDb.close();

      // One rename replaces the active file in a single step, so there's
      // never a moment without it, for this or any other process. Open
      // connections keep reading the replaced file until they close.
      await stagingFile.rename(activeFile.path);
      _deferredStagingPaths.remove(locale);

      // Queries already running on the old connection get time to finish,
      // on the replaced file.
      final previousDb = _databases.remove(locale);
      if (previousDb != null && previousDb.isOpen) {
        unawaited(Future<void>.delayed(const Duration(seconds: 30), previousDb.close));
      }
      _databases[locale] = await _initDB(activeFile.path);
      _contentsChanged();

      // Tell other isolates to reopen; this one already has the new file.
      // The new file stays installed if this fails, but the refresh reports
      // it as failed, since other isolates keep reading the replaced file.
      final generation = DateTime.now().microsecondsSinceEpoch.toString();
      await _generationFile(dbDir.path).writeAsString(generation, flush: true);
      _openedGenerations[locale] = generation;
    } finally {
      if (swapping) cancelToken?.endUncancellable();
      try {
        if (stagingDb != null) await stagingDb.close();
        if (stagingFile != null &&
            !(preserveStagingFile && populateSucceeded)) {
          if (_deferredStagingPaths[locale] == stagingFile.path) {
            _deferredStagingPaths.remove(locale);
          }
          if (await stagingFile.exists()) await stagingFile.delete();
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

  /// Deletes the locale's database and its side files, when the region is
  /// turned off. Waits for any refresh of it to finish first, and holds new
  /// lookups until the files are gone. Other isolates drop their connection
  /// once they see the generation file is gone.
  Future<void> deleteLocaleData() async {
    final previousRefresh = _refreshTails[locale] ?? Future<void>.value();
    final deleteFinished = Completer<void>();
    _refreshTails[locale] = deleteFinished.future;
    await previousRefresh;

    final barrier = Completer<void>();
    _replacementBarriers[locale] = barrier.future;
    try {
      final cachedDb = _databases.remove(locale);
      if (cachedDb != null && cachedDb.isOpen) await cachedDb.close();
      _contentsChanged();
      _deferredStagingPaths.remove(locale);
      _openedGenerations.remove(locale);
      _generationCheckedAt.remove(locale);

      final dbPath = '${(await AppGroupStorage.directory).path}/gtfs/$locale.db';
      for (final suffix in ['', '-journal', '-wal', '-shm', '.backup']) {
        final file = File('$dbPath$suffix');
        if (await file.exists()) await file.delete();
      }
      final generationFile = _generationFile(File(dbPath).parent.path);
      if (await generationFile.exists()) await generationFile.delete();
    } finally {
      _replacementBarriers.remove(locale);
      barrier.complete();
      deleteFinished.complete();
      if (identical(_refreshTails[locale], deleteFinished.future)) {
        _refreshTails.remove(locale);
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
      version: 3,
      // Not sqflite's default single instance per path: while a replaced
      // file's old connection is still open, that would hand back the old
      // connection, still on the replaced file. [_opening] keeps callers
      // from opening the same file twice instead.
      singleInstance: false,
      onCreate: _createDB,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createCalendarDatesTable(db);
          await _createAgenciesTable(db);
          await db.execute(
            "ALTER TABLE gtfs_routes ADD COLUMN agency_id TEXT NOT NULL DEFAULT ''",
          );
        }
        if (oldVersion < 3) {
          // match_confidence became match_distance_meters, as it holds a
          // distance. The table is rebuilt because RENAME COLUMN needs
          // SQLite 3.25, newer than Android's before API 30.
          await db.execute('ALTER TABLE stop_mapping RENAME TO stop_mapping_old');
          await _createStopMappingTable(db);
          await db.execute('''INSERT INTO stop_mapping
            (operator_stop_id, gtfs_stop_id, match_distance_meters)
            SELECT operator_stop_id, gtfs_stop_id, match_confidence
            FROM stop_mapping_old''');
          await db.execute('DROP TABLE stop_mapping_old');
        }
      },
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''CREATE TABLE gtfs_routes (
    route_id TEXT PRIMARY KEY, 
    route_short_name TEXT NOT NULL,
    agency_id TEXT NOT NULL DEFAULT ''
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

    await _createStopMappingTable(db);

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
      '''CREATE INDEX idx_stop_times_trip_ends ON gtfs_stop_times(trip_id, stop_sequence, stop_id)''',
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

  /// Links operator stops to GTFS stops, with how far apart the two are.
  Future<void> _createStopMappingTable(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE stop_mapping (
    operator_stop_id TEXT PRIMARY KEY REFERENCES operator_stops(operator_stop_id),
    gtfs_stop_id TEXT NOT NULL REFERENCES gtfs_stops(stop_id),
    match_distance_meters REAL
    )''');
  }

  Future<void> _createAgenciesTable(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE gtfs_agencies (
      agency_id TEXT PRIMARY KEY,
      agency_name TEXT NOT NULL,
      agency_noc TEXT
    )''');
  }

  /// Inserts [rows] (values in [columns] order) with as few statements as
  /// possible: many rows per INSERT, within SQLite's 999 bound-parameter limit
  /// on older Android versions. [replace] makes it INSERT OR REPLACE, for
  /// tables keyed by GTFS IDs that later archives may repeat.
  Future<void> _insertRows(
    DatabaseExecutor db,
    String table,
    List<String> columns,
    List<List<Object?>> rows, {
    bool replace = false,
  }) async {
    if (rows.isEmpty) return;
    final rowsPerStatement = 999 ~/ columns.length;
    final verb = replace ? 'INSERT OR REPLACE' : 'INSERT';
    final rowPlaceholders = '(${List.filled(columns.length, '?').join(',')})';
    final batch = db.batch();
    for (var start = 0; start < rows.length; start += rowsPerStatement) {
      final end = math.min(start + rowsPerStatement, rows.length);
      batch.rawInsert(
        '$verb INTO $table (${columns.join(', ')}) VALUES '
        '${List.filled(end - start, rowPlaceholders).join(',')}',
        [for (var i = start; i < end; i++) ...rows[i]],
      );
    }
    await batch.commit(noResult: true);
    _contentsChanged();
  }

  /// Drops lookups cached from this database, after its contents change.
  /// Only this isolate's: other isolates notice a swap through the
  /// generation file, but not changes written in place.
  void _contentsChanged() => _routesForStopCache.clear();

  /// Imports [rows] of the GTFS file [fileName] into [table], whose columns
  /// are named as in the file. A missing required column is a
  /// FormatException; a missing optional one, or a short row, reads as an
  /// empty value. [keep] can leave out a row after its values are parsed.
  Future<void> _insertGtfsRows(
    String fileName,
    String table,
    List<dynamic> header,
    List<List<dynamic>> rows,
    List<_GtfsColumn> columns, {
    bool replace = true,
    bool Function(List<Object?> values)? keep,
  }) async {
    final indexes = <int>[];
    for (final column in columns) {
      final index = header.indexOf(column.name);
      if (index < 0 && column.required) {
        throw FormatException('GTFS $fileName is missing the ${column.name} column.');
      }
      indexes.add(index);
    }

    final values = <List<Object?>>[];
    for (final row in rows) {
      final parsed = [
        for (var i = 0; i < columns.length; i++)
          columns[i].parse(
            indexes[i] >= 0 && row.length > indexes[i] ? row[indexes[i]].toString() : '',
          ),
      ];
      if (keep == null || keep(parsed)) values.add(parsed);
    }

    final db = await database;
    await db.transaction((txn) => _insertRows(
      txn, table, [for (final column in columns) column.name], values, replace: replace,
    ));
  }

  Future<void> batchInsertRoutes(List<dynamic> header, List<List<dynamic>> rows) =>
      _insertGtfsRows('routes.txt', 'gtfs_routes', header, rows, [
        _text('route_id'),
        _text('route_short_name'),
        // Optional in GTFS when the feed has one agency; matches that
        // agency's empty ID then.
        _text('agency_id', required: false),
      ]);

  Future<void> batchInsertAgencies(List<dynamic> header, List<List<dynamic>> rows) =>
      _insertGtfsRows('agency.txt', 'gtfs_agencies', header, rows, [
        // Optional in GTFS when the feed has one agency, stored empty.
        _text('agency_id', required: false),
        _text('agency_name'),
        _text('agency_noc', required: false),
      ]);

  Future<void> batchInsertTrips(List<dynamic> header, List<List<dynamic>> rows) =>
      _insertGtfsRows('trips.txt', 'gtfs_trips', header, rows, [
        _text('route_id'),
        _text('service_id'),
        _text('trip_id'),
        _int('direction_id'),
      ]);

  Future<void> batchInsertCalendar(List<dynamic> header, List<List<dynamic>> rows) =>
      _insertGtfsRows('calendar.txt', 'gtfs_calendar', header, rows, [
        _text('service_id'),
        for (final day in const ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'])
          _int(day),
        _text('start_date'),
        _text('end_date'),
      ]);

  Future<void> batchInsertCalendarDates(List<dynamic> header, List<List<dynamic>> rows) =>
      _insertGtfsRows('calendar_dates.txt', 'gtfs_calendar_dates', header, rows, [
        _text('service_id'),
        _text('date'),
        _int('exception_type'),
      ]);

  Future<void> batchInsertStops(List<dynamic> header, List<List<dynamic>> rows) =>
      _insertGtfsRows(
        'stops.txt',
        'gtfs_stops',
        header,
        rows,
        [
          _text('stop_id'),
          _text('stop_name'),
          _double('stop_lat'),
          _double('stop_lon'),
        ],
        // A stop without a position (missing, or 0,0) can't be shown on the
        // map or matched, so it's left out.
        keep: (values) => switch ((values[2], values[3])) {
          (final double lat, final double lon) => lat != 0 || lon != 0,
          _ => false,
        },
      );

  Future<void> batchInsertStopTimes(List<dynamic> header, List<List<dynamic>> rows) =>
      _insertGtfsRows(
        'stop_times.txt',
        'gtfs_stop_times',
        header,
        rows,
        [
          _text('trip_id'),
          (name: 'arrival_time', required: true, parse: _normalizedTime),
          (name: 'departure_time', required: true, parse: _normalizedTime),
          _text('stop_id'),
          _int('stop_sequence'),
        ],
        // No unique key to replace on, so rows are only ever added.
        replace: false,
      );

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
    _contentsChanged();
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
    _contentsChanged();
  }

  /// Removes operator routes and their stop lists, such as a direction a
  /// provider lists but doesn't run.
  Future<void> deleteOperatorRoutes(Iterable<String> operatorRouteIds) async {
    final batch = (await database).batch();
    for (final id in operatorRouteIds) {
      batch.delete("route_stops", where: "operator_route_id = ?", whereArgs: [id]);
      batch.delete("operator_routes", where: "operator_route_id = ?", whereArgs: [id]);
    }
    await batch.commit(noResult: true);
    _contentsChanged();
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

    await batch.commit(noResult: true);
    _contentsChanged();
  }

  Future<void> interpolateMissingArrivalTimes({
    CancellationToken? cancelToken,
  }) async {
    final db = await database;
    final tripIds = await db.rawQuery(
      "SELECT DISTINCT trip_id FROM gtfs_stop_times",
    );
    var batch = db.batch();
    var processedTrips = 0;

    for (final tripRow in tripIds) {
      cancelToken?.throwIfCancelled();
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
        // A fresh batch every 500 trips keeps memory down and each commit fast.
        batch = db.batch();
      }
    }
    await batch.commit(noResult: true);
    _contentsChanged();
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
          "$opStopId (name matched ${nameCandidates.length} GTFS stops, picked nearest)",
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
        "match_distance_meters": bestDistance,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    await batch.commit(noResult: true);
    _contentsChanged();

    if (ambiguousMatches.isNotEmpty) {
      debugPrint(
        "${ambiguousMatches.length} operator stops matched several GTFS stops by name: ${ambiguousMatches.join(", ")}",
      );
    }
    if (noMatches.isNotEmpty) {
      debugPrint(
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
            bound: row["bound"] as String? ?? '',
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
    final Database db;
    try {
      db = await database;
    } on LocaleDataMissingException {
      return false;
    }
    final rows = await db.rawQuery('''
      SELECT
        EXISTS(SELECT 1 FROM gtfs_routes) AS routes,
        EXISTS(SELECT 1 FROM gtfs_trips) AS trips,
        EXISTS(SELECT 1 FROM gtfs_calendar) AS calendar,
        EXISTS(SELECT 1 FROM gtfs_stops) AS stops,
        EXISTS(SELECT 1 FROM gtfs_stop_times) AS stop_times
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

  /// The next [limit] timetabled departures from [stopId], on the locale's
  /// clock. Trips from yesterday's service day still running after midnight
  /// (GTFS times of 24:00:00 and later) are included, with their times
  /// brought back to today's.
  Future<List<ScheduledDeparture>> getUpcomingDepartures(
    String stopId, {
    int limit = 5,
  }) async {
    final db = await database;
    final now = LocaleRegistry.getLocale(locale).config.nowInLocale();
    final today = DateTime.utc(now.year, now.month, now.day);
    final yesterday = DateTime.utc(now.year, now.month, now.day - 1);

    final rows = [
      ...await _departuresOnServiceDay(
        db,
        stopId,
        today,
        after: _secondsToTime(now.hour * 3600 + now.minute * 60 + now.second),
        limit: limit,
      ),
      for (final row in await _departuresOnServiceDay(
        db,
        stopId,
        yesterday,
        after: _secondsToTime((now.hour + 24) * 3600 + now.minute * 60 + now.second),
        limit: limit,
      ))
        {
          ...row,
          "arrival_time": _secondsToTime(
            _timeToSeconds(row["arrival_time"] as String) - 24 * 3600,
          ),
        },
    ]..sort((a, b) => (a["arrival_time"] as String).compareTo(b["arrival_time"] as String));

    return rows.take(limit).map((row) {
      final destinationName = row["destination_name"] as String?;
      return ScheduledDeparture(
        routeShortName: row["route_short_name"] as String,
        arrivalTime: row["arrival_time"] as String,
        // todo fix multilang support
        destination: destinationName == null ? {} : {"en": destinationName},
        directionId: row["direction_id"] as int?,
        tripId: row["trip_id"] as String?,
        locale: locale,
      );
    }).toList();
  }

  /// Departures from [stopId] after the GTFS time [after] on the service
  /// day [day], counting calendar_dates exceptions, with each trip's last
  /// stop as its destination.
  Future<List<Map<String, Object?>>> _departuresOnServiceDay(
    Database db,
    String stopId,
    DateTime day, {
    required String after,
    required int limit,
  }) {
    const weekDays = [
      "monday",
      "tuesday",
      "wednesday",
      "thursday",
      "friday",
      "saturday",
      "sunday",
    ];
    final dayColumn = weekDays[day.weekday - 1];
    final dateStr =
        "${day.year}${day.month.toString().padLeft(2, "0")}${day.day.toString().padLeft(2, "0")}";

    return db.rawQuery(
      '''
    WITH upcoming AS (
      SELECT r.route_short_name, st.arrival_time, t.direction_id, t.trip_id
      FROM gtfs_stop_times AS st
      INNER JOIN gtfs_trips AS t ON st.trip_id = t.trip_id
      INNER JOIN gtfs_routes AS r ON t.route_id = r.route_id
      WHERE st.stop_id = ?
        AND st.arrival_time > ?
        -- Runs that day by its weekly calendar or as an added date, and
        -- isn't removed for that date.
        AND (
          EXISTS (
            SELECT 1 FROM gtfs_calendar AS c
            WHERE c.service_id = t.service_id
              AND c.$dayColumn = 1
              AND c.start_date <= ?
              AND c.end_date >= ?
          )
          OR EXISTS (
            SELECT 1 FROM gtfs_calendar_dates AS added
            WHERE added.service_id = t.service_id
              AND added.date = ? AND added.exception_type = 1
          )
        )
        AND NOT EXISTS (
          SELECT 1 FROM gtfs_calendar_dates AS removed
          WHERE removed.service_id = t.service_id
            AND removed.date = ? AND removed.exception_type = 2
        )
      ORDER BY st.arrival_time ASC
      LIMIT ?
    )
    SELECT u.route_short_name, u.arrival_time, u.direction_id, u.trip_id,
      (SELECT s.stop_name
        FROM gtfs_stop_times AS lt
        INNER JOIN gtfs_stops AS s ON s.stop_id = lt.stop_id
        WHERE lt.trip_id = u.trip_id
        ORDER BY lt.stop_sequence DESC
        LIMIT 1) AS destination_name
    FROM upcoming AS u
    ORDER BY u.arrival_time ASC
    ''',
      [stopId, after, dateStr, dateStr, dateStr, dateStr, limit],
    );
  }

  Future<List<GtfsStop>> getAllGtfsStops({String? languageCode}) async {
    // A region with no data yet, such as one being downloaded after a region
    // change, has no stops rather than failing the whole map.
    try {
      await database;
    } on LocaleDataMissingException {
      return [];
    }
    if (LocaleRegistry.getLocale(locale).gtfsOnly) {
      // todo may need to adapt for multilang names
      final rows = await (await database).rawQuery(
        '''SELECT * FROM gtfs_stops''',
      );
      return rows
          .map(
            (s) => GtfsStop(
              id: s["stop_id"].toString(),
              name: s["stop_name"].toString(),
              lat: double.parse(s["stop_lat"].toString()),
              lng: double.parse(s["stop_lon"].toString()),
              locale: locale,
            ),
          )
          .toList();
    } else {
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
  }

  Future<List<TransportRoute>> getRoutesForGtfsStop(String gtfsStopId) async {
    final cached = _routesForStopCache.putIfAbsent(
      gtfsStopId,
      () => _queryRoutesForGtfsStop(gtfsStopId),
    );
    try {
      return List.of(await cached);
    } catch (_) {
      // Don't keep a failed lookup; the next caller retries the query.
      if (identical(_routesForStopCache[gtfsStopId], cached)) {
        _routesForStopCache.remove(gtfsStopId);
      }
      rethrow;
    }
  }

  Future<List<TransportRoute>> _queryRoutesForGtfsStop(String gtfsStopId) async {
    // todo check query on circular routes
    if (LocaleRegistry.getLocale(locale).gtfsOnly) {
      // todo adapt for multilingual names
      final rows = await (await database).rawQuery(
        '''
      WITH matching_trips AS (
        SELECT DISTINCT st.trip_id
        FROM gtfs_stop_times st
        WHERE st.stop_id = ?
          -- Not trips that end here, as they never depart from this stop.
          -- Checked per trip: some of a route's trips may end early.
          AND st.stop_sequence < (
            SELECT MAX(x.stop_sequence) FROM gtfs_stop_times x
            WHERE x.trip_id = st.trip_id
          )
      ), trip_ends AS (
        SELECT mt.trip_id,
          (SELECT x.stop_id FROM gtfs_stop_times x
            WHERE x.trip_id = mt.trip_id
            ORDER BY x.stop_sequence ASC LIMIT 1) AS first_stop_id,
          (SELECT x.stop_id FROM gtfs_stop_times x
            WHERE x.trip_id = mt.trip_id
            ORDER BY x.stop_sequence DESC LIMIT 1) AS last_stop_id
        FROM matching_trips mt
      )
      SELECT DISTINCT gr.route_id, gr.route_short_name,
        -- A route whose agency isn't in agency.txt, or has no name, is
        -- kept under a made-up name rather than dropped.
        COALESCE(NULLIF(ga.agency_name, ''), 'Unknown operator') AS agency_name,
        ga.agency_noc, gt.direction_id, first_stop.stop_name AS first_stop_name, last_stop.stop_name AS last_stop_name
      FROM trip_ends te
      INNER JOIN gtfs_trips gt ON gt.trip_id = te.trip_id
      INNER JOIN gtfs_routes gr ON gr.route_id = gt.route_id
      LEFT JOIN gtfs_agencies ga ON ga.agency_id = gr.agency_id
      LEFT JOIN gtfs_stops first_stop ON first_stop.stop_id = te.first_stop_id
      LEFT JOIN gtfs_stops last_stop ON last_stop.stop_id = te.last_stop_id;
      ''',
        [gtfsStopId],
      );

      return rows
          .map(
            (row) => TransportRoute(
              id: row["route_id"].toString(),
              names: { // todo add multilingual compat
                "en": row["route_short_name"].toString(),
              }, // route_short_name
              routeNumber: row["route_short_name"].toString(), // append agency name before number, same as names
              bound: row["direction_id"].toString(),
              originText: { // todo add multilingual compat
                "en": row["first_stop_name"].toString(),
              }, // resolve from stop_id where seq = 0 from gtfs_stop_times
              destinationText: { // todo add multilingual compat
                "en": row["last_stop_name"].toString(),
              }, // resolve from stop_id where seq = max
              providerCode: LocaleRegistry.getLocale(locale) // todo add multi provider compat
                  .transitProviders[0]
                  .providerCode,
              locale: locale,
              agency: row["agency_name"].toString(),
              agencyNoc: row["agency_noc"]?.toString(),
            ),
          )
          .toList();
    } else {
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
              names: Map<String, String>.from(
                jsonDecode(row["names"] as String),
              ),
              routeNumber: row["route_number"] as String,
              bound: row["bound"] as String? ?? '',
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
  }

  Future<List<String>> getOperatorStopIds(
    String gtfsStopId, {
    String? providerCode,
  }) async {
    if (LocaleRegistry.getLocale(locale).gtfsOnly) {
      return [
        "${LocaleRegistry.getLocale(locale).transitProviders[0].providerCode}:$gtfsStopId",
      ];
    } else {
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
    if (LocaleRegistry.getLocale(locale).gtfsOnly) {
      return GtfsStop( // early out for gtfs only locales
        id: rows[0]["stop_id"] as String,
        name: rows[0]["stop_name"] as String,
        lat: rows[0]["stop_lat"] as double,
        lng: rows[0]["stop_lon"] as double,
        locale: locale
      );
    }
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

  int _timeToSeconds(String hhmmss) {
    final parts = hhmmss.split(":");
    return int.parse(parts[0]) * 3600 +
        int.parse(parts[1]) * 60 +
        int.parse(parts[2]);
  }

  /// A GTFS time as zero-padded "HH:MM:SS", since GTFS allows "9:05:00" and
  /// times are compared and sorted as text. Empty (to be interpolated) and
  /// unreadable values are kept as they are.
  String _normalizedTime(String raw) {
    final time = raw.trim();
    final parts = time.split(":");
    if (parts.length != 3) return time;
    final hours = int.tryParse(parts[0]);
    final minutes = int.tryParse(parts[1]);
    final seconds = int.tryParse(parts[2]);
    if (hours == null || minutes == null || seconds == null) return time;
    return _secondsToTime(hours * 3600 + minutes * 60 + seconds);
  }

  String _secondsToTime(int totalSeconds) {
    return "${(totalSeconds ~/ 3600).toString().padLeft(2, "0")}:${((totalSeconds % 3600) ~/ 60).toString().padLeft(2, "0")}:${(totalSeconds % 60).toString().padLeft(2, "0")}";
  }
}

/// A column of a GTFS file and its table, and how to read its value.
typedef _GtfsColumn = ({String name, bool required, Object? Function(String value) parse});

_GtfsColumn _text(String name, {bool required = true}) =>
    (name: name, required: required, parse: (value) => value);

/// Optional; a missing or unreadable value is 0.
_GtfsColumn _int(String name) =>
    (name: name, required: false, parse: (value) => int.tryParse(value) ?? 0);

/// Optional; a missing or unreadable value is null.
_GtfsColumn _double(String name) =>
    (name: name, required: false, parse: double.tryParse);
