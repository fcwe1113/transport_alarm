import 'dart:convert';
import 'dart:io';

import 'package:transport_alarm/models/scheduled_departure.dart';
import 'package:transport_alarm/provider_registry.dart';
import 'package:transport_alarm/services/geo_utils.dart';
import 'package:transport_alarm/transit/models/bus_stop.dart';
import 'package:transport_alarm/transit/models/gtfs_stop.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:sqflite/sqflite.dart';

import '../models/bus_route.dart';

class GtfsDatabase {
  static final Map<String, GtfsDatabase> _instances = {};
  static final Map<String, Database?> _databases = {};
  final String locale;

  GtfsDatabase._(this.locale);

  factory GtfsDatabase.forLocale(String locale) {
    return _instances.putIfAbsent(locale, () => GtfsDatabase._(locale));
  }

  Future<Database> get database async {
    if (_databases.containsKey(locale) && _databases[locale]!.isOpen) {
      return _databases[locale]!;
    }
    final dir = Directory('${(await AppGroupStorage.directory).path}/gtfs');
    await dir.create(recursive: true);
    final db = await _initDB('${dir.path}/gtfs/$locale.db');
    _databases[locale] = db;
    return db;
  }

  Future<Database> _initDB(String filePath) async {
    return await openDatabase(filePath, version: 1, onCreate: _createDB);
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''CREATE TABLE gtfs_routes (
    route_id TEXT PRIMARY KEY, 
    route_short_name TEXT NOT NULL
    )''');

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

    await db.execute('''CREATE INDEX idx_routes_name ON gtfs_routes(route_short_name)''');
    await db.execute('''CREATE INDEX idx_trips_route_service ON gtfs_trips(route_id, service_id)''');
    await db.execute('''CREATE INDEX idx_stop_times_lookup ON gtfs_stop_times(stop_id, arrival_time)''');
    await db.execute('''CREATE INDEX idx_operator_stops_provider ON operator_stops(provider_code)''');
    await db.execute('''CREATE INDEX idx_stop_times_trip ON gtfs_stop_times(trip_id)''');
  }

  String _val(List<dynamic> row, int index) => row.length > index ? row[index].toString() : "";

  Future<void> batchInsertRoutes(List<List<dynamic>> rows) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var row in rows.skip(1)) {
        batch.insert("gtfs_routes", {
          "route_id": _val(row, 0),
          "route_short_name": _val(row, 2),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> batchInsertTrips(List<List<dynamic>> rows) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var row in rows.skip(1)) {
        batch.insert("gtfs_trips", {
          "route_id": _val(row, 0),
          "service_id": _val(row, 1),
          "trip_id": _val(row, 2),
          "direction_id": int.tryParse(_val(row, 5)) ?? 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> batchInsertCalendar(List<List<dynamic>> rows) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var row in rows.skip(1)) {
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

  Future<void> batchInsertStops(List<List<dynamic>> rows) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var row in rows.skip(1)) {
        batch.insert("gtfs_stops", {
          "stop_id": _val(row, 0),
          "stop_name": _val(row, 1),
          "stop_lat": double.tryParse(_val(row, 2)) ?? 0,
          "stop_lon": double.tryParse(_val(row, 3)) ?? 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> batchInsertStopTimes(List<List<dynamic>> rows) async {
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (var row in rows.skip(1)) {
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

  Future<void> upsertOperatorStops(List<BusStop> stops) async {
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

  Future<void> upsertOperatorRoutes(List<BusRoute> routes) async {
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

  Future<void> upsertRouteStops(String operatorRouteId, List<String> operatorStopIds) async {
    final batch = (await database).batch();
    batch.delete("route_stops", where: "operator_route_id = ?", whereArgs: [operatorRouteId]);
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
    final tripIds = await db.rawQuery("SELECT DISTINCT trip_id FROM gtfs_stop_times");
    var batch = db.batch();
    var processedTrips = 0;

    for (final tripRow in tripIds) {
      final tripId = tripRow["trip_id"] as String;
      final stopTimes = await db.query("gtfs_stop_times", where: "trip_id = ?", whereArgs: [tripId], orderBy: "stop_sequence ASC");

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

        final startSeconds = _timeToSeconds(stopTimes[startIdx]["arrival_time"] as String);
        final endSeconds = _timeToSeconds(stopTimes[endIdx]["arrival_time"] as String);
        final totalSteps = endIdx - startIdx;

        for (var j = startIdx + 1; j < endIdx; j++) {
          final fraction = (j - startIdx) / totalSteps;
          final interpolatedSeconds = startSeconds + ((endSeconds - startSeconds) * fraction).round();
          final interpolatedTime = _secondsToTime(interpolatedSeconds);

          batch.update("gtfs_stop_times", {"arrival_time": interpolatedTime, "departure_time": interpolatedTime},
              where: "trip_id = ? AND stop_sequence = ?",
              whereArgs: [tripId, stopTimes[j]["stop_sequence"]]
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

  Future<void> matchOperatorStopsToGtfs({double maxDistanceMeters = 150}) async {
    final db = await database;
    final operatorRows = await db.query("operator_stops", where: "lat IS NOT NULL AND lng IS NOT NULL");
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
      final opName = (jsonDecode(opRow["names"] as String) as Map<String, dynamic>)["en"] as String? ?? "";
      
      final normalizedOpName = GtfsStop.normalizeForMatching(opName);
      final nameCandidates = nameIndex[normalizedOpName] ?? [];

      String? bestGtfsId;
      double bestDistance;

      if (nameCandidates.length == 1) {
        bestGtfsId = nameCandidates.first["stop_id"] as String;
        bestDistance = haversineDistanceMeters(opLat, opLng, nameCandidates.first["stop_lat"] as double, nameCandidates.first["stop_lon"] as double
        );
      } else if (nameCandidates.length > 1) {
        bestGtfsId = null;
        bestDistance = double.infinity;
        for (final candidate in nameCandidates) {
          final d = haversineDistanceMeters(opLat, opLng, candidate["stop_lat"] as double, candidate["stop_lon"] as double
          );
          if (d < bestDistance) {
            bestDistance = d;
            bestGtfsId = candidate["stop_id"] as String;
          }
        }
        ambiguousMatches.add("${opStopId} (name matched ${nameCandidates.length} GTFS stops, picked nearest)");
      } else {
        bestGtfsId = null;
        bestDistance = double.infinity;
        for (final gRow in gtfsRows) {
          final d = haversineDistanceMeters(opLat, opLng,
              gRow["stop_lat"] as double, gRow["stop_lon"] as double
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
      print("${ambiguousMatches.length} operator stops matched ambigiously (top 2 candidates within 20m): ${ambiguousMatches.join(", ")}");
    }
    if (noMatches.isNotEmpty) {
      print("${noMatches.length} matched by proximity only (no name match found): ${noMatches.join(", ")}");
    }
  }

  Future<List<BusRoute>> getOperatorRoutes(String providerCode) async {
    final rows = await (await database).query("operator_routes", where: "provider_code = ?", whereArgs: [providerCode]);
    
    return rows.map((row) => BusRoute(
        id: row["operator_route_id"] as String,
        names: Map<String, String>.from(jsonDecode(row["names"] as String)),
        routeNumber: row["route_number"] as String,
        bound: row["bound"] as String,
        originText: Map<String, String>.from(jsonDecode(row["origin_text"] as String)),
        destinationText: Map<String, String>.from(jsonDecode(row["destination_text"] as String)),
        providerCode: row["provider_code"] as String
    )).toList();
  }

  Future<List<ScheduledDeparture>> getUpcomingDepartures(String stopId, {int limit = 5}) async {
    final db = await database;
    final now = localeConfigs[locale]!.nowInLocale();

    final weekDays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"];
    final currentDayColumn = weekDays[now.weekday - 1];

    final timeStr = "${now.hour.toString().padLeft(2, "0")}:${now.minute.toString().padLeft(2, "0")}:${now.second.toString().padLeft(2, "0")}";
    final dateStr = "${now.year}${now.month.toString().padLeft(2, "0")}${now.day.toString().padLeft(2, "0")}";

    final List<Map<String, dynamic>> rows = await db.rawQuery('''
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
    ''', [stopId, timeStr, dateStr, dateStr, limit]);

    return rows.map((row) => ScheduledDeparture(
        routeShortName: row["route_short_name"] as String,
        arrivalTime: row["arrival_time"] as String,
        directionId: row["direction_id"] as int?,
        locale: locale
    )).toList();
  }

  Future<List<GtfsStop>> getAllGtfsStops() async {
    // query to only include stops with mapped routes
    final rows = await (await database).rawQuery('''
    SELECT DISTINCT s.*
    FROM gtfs_stops s
    INNER JOIN stop_mapping sm on sm.gtfs_stop_id = s.stop_id
    ''');
    return rows.map((row) => GtfsStop(id: row["stop_id"] as String, name: row["stop_name"] as String, lat: row["stop_lat"] as double, lng: row["stop_lon"] as double)).toList();
  }

  Future<List<BusRoute>> getRoutesForGtfsStop(String gtfsStopId) async { // todo check query on circular routes
    final rows = await (await database).rawQuery('''
    SELECT DISTINCT r.*
    FROM operator_routes r
    INNER JOIN route_stops rs ON rs.operator_route_id = r.operator_route_id
    INNER JOIN stop_mapping sm ON sm.operator_stop_id = rs.operator_stop_id
    WHERE sm.gtfs_stop_id = ? AND rs.stop_sequence < (
      SELECT MAX(rs2.stop_sequence)
      FROM route_stops rs2
      WHERE rs2.operator_route_id = rs.operator_route_id
    )
    ''', [gtfsStopId]);
    
    return rows.map((row) => BusRoute(
        id: row["operator_route_id"] as String,
        names: Map<String, String>.from(jsonDecode(row["names"] as String)),
        routeNumber: row["route_number"] as String,
        bound: row["bound"] as String,
        originText: Map<String, String>.from(jsonDecode(row["origin_text"] as String)),
        destinationText: Map<String, String>.from(jsonDecode(row["destination_text"] as String)),
        providerCode: row["provider_code"] as String
    )).toList();
  }

  Future<List<String>> getOperatorStopIds(String gtfsStopId, {String? providerCode}) async {
    final where = providerCode != null ? "sm.gtfs_stop_id = ? AND os.provider_code = ?" : "sm.gtfs_stop_id = ?";
    final whereArgs = providerCode != null ? [gtfsStopId, providerCode] : [gtfsStopId];

    final rows = await (await database).rawQuery('''
    SELECT sm.operator_stop_id
    FROM stop_mapping sm
    INNER JOIN operator_stops os ON os.operator_stop_id = sm.operator_stop_id
    WHERE $where
    ''', whereArgs);

    return rows.map((r) => r["operator_stop_id"] as String).toList();
  }

  Future<GtfsStop?> getGtfsStopById(String stopId) async {
    final rows = await (await database).query("gtfs_stops", where: "stop_id = ?", whereArgs: [stopId]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return GtfsStop(
      id: row["stop_id"] as String,
      name: GtfsStop.cleanStopName(row["stop_name"] as String),
      lat: row["stop_lat"] as double,
      lng: row["stop_lon"] as double,
    );
  }

  Future<List<String>> getRouteNumbersForOperatorStop(String operatorStopId) async {
    final rows = await (await database).rawQuery('''
    SELECT r.route_number
    FROM route_stops rs
    INNER JOIN operator_routes r ON r.operator_route_id = rs.operator_route_id
    WHERE rs.operator_stop_id = ?
    ''', [operatorStopId]);
    return rows.map((row) => row["route_number"] as String).toList();
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
  }

  int _timeToSeconds(String hhmmss) {
    final parts = hhmmss.split(":");
    return int.parse(parts[0]) * 3600 + int.parse(parts[1]) * 60 + int.parse(parts[2]);
  }

  String _secondsToTime(int totalSeconds) {
    return "${(totalSeconds ~/ 3600).toString().padLeft(2, "0")}:${((totalSeconds % 3600) ~/ 60).toString().padLeft(2, "0")}:${(totalSeconds % 60).toString().padLeft(2, "0")}";
  }
}
