import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:transport_alarm/locale_registry.dart';
import 'package:transport_alarm/transit/models/live_eta.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/refresh_result.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/transit_provider.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:xml/xml.dart';

class GbBodsProvider extends TransitProvider {
  final ApiCaller _apiCaller;
  final GtfsDatabase db = LocaleRegistry.getLocale("gb").db;
  Future<String> _apiKey() async {
    final source = await rootBundle.loadString('config/secrets.json');
    final key = jsonDecode(source)['UK_BODS_KEY'];
    return key.trim();
  }

  GbBodsProvider(this._apiCaller);

  /// Parses a GTFS time (which may exceed 24 hours) into seconds from midnight.
  int? _gtfsTimeSeconds(Object? value) {
    final parts = value?.toString().split(':');
    if (parts == null || parts.length != 3) return null;
    final hours = int.tryParse(parts[0]);
    final minutes = int.tryParse(parts[1]);
    final seconds = int.tryParse(parts[2]);
    if (hours == null || minutes == null || seconds == null) return null;
    return hours * 3600 + minutes * 60 + seconds;
  }

  /// Measures point-to-segment distance and the clamped fraction along the pair.
  ({double distanceMeters, double fraction}) _projectOntoStopPair(
    double latitude,
    double longitude,
    double fromLatitude,
    double fromLongitude,
    double toLatitude,
    double toLongitude,
  ) {
    const metersPerDegree = 111320.0;
    final meanLatitude = (fromLatitude + toLatitude + latitude) / 3;
    final longitudeScale = math.cos(meanLatitude * math.pi / 180);
    final bx = (toLongitude - fromLongitude) * metersPerDegree * longitudeScale;
    final by = (toLatitude - fromLatitude) * metersPerDegree;
    final px = (longitude - fromLongitude) * metersPerDegree * longitudeScale;
    final py = (latitude - fromLatitude) * metersPerDegree;
    final lengthSquared = bx * bx + by * by;
    final fraction = lengthSquared == 0
        ? 0.0
        : ((px * bx + py * by) / lengthSquared).clamp(0.0, 1.0).toDouble();
    final dx = px - fraction * bx;
    final dy = py - fraction * by;
    return (distanceMeters: math.sqrt(dx * dx + dy * dy), fraction: fraction);
  }

  @override
  Color get defaultIconColor => const Color(0xFF1A006E);

  @override
  Color get defaultTextColor => Colors.white;

  @override
  Future<List<LiveEta>> fetchLiveEta(String rawStopId) async {
    final routeList = await (await db.database).rawQuery(
      '''
    SELECT DISTINCT gr.route_short_name , ga.agency_name , ga.agency_noc
    FROM gtfs_stops gs
    INNER JOIN gtfs_stop_times gst on gs.stop_id = gst.stop_id
    INNER JOIN gtfs_trips gt on gst.trip_id = gt.trip_id
    INNER JOIN gtfs_routes gr on gt.route_id = gr.route_id
    INNER JOIN gtfs_agencies ga on gr.agency_id = ga.agency_id
    WHERE gs.stop_id = ?''',
      [rawStopId],
    );

    final routeNumbers = routeList
        .map((row) => row['route_short_name']?.toString() ?? '')
        .where((routeNumber) => routeNumber.isNotEmpty)
        .toSet();
    final etas = <LiveEta>[];
    for (final routeNumber in routeNumbers) {
      etas.addAll(await fetchLiveEtaForRoute(rawStopId, routeNumber));
    }
    return etas;
  }

  @override
  Future<List<LiveEta>> fetchLiveEtaForRoute(
    String rawStopId,
    String routeNumber,
  ) async {
    final db = await this.db.database;
    final noc = (await db.rawQuery(
      // there should only be one
      '''
    SELECT DISTINCT ga.agency_noc
    FROM gtfs_stops gs
    INNER JOIN gtfs_stop_times gst on gs.stop_id = gst.stop_id
    INNER JOIN gtfs_trips gt on gst.trip_id = gt.trip_id
    INNER JOIN gtfs_routes gr on gt.route_id = gr.route_id
    INNER JOIN gtfs_agencies ga on gr.agency_id = ga.agency_id
    WHERE gs.stop_id = ? AND gr.route_short_name = ?''',
      [rawStopId, routeNumber],
    ))[0]["agency_noc"].toString();

    final apiKey = await _apiKey();

    final uri = Uri.https('data.bus-data.dft.gov.uk', '/api/v1/datafeed/', {
      'api_key': apiKey,
      'lineRef': routeNumber,
      'operatorRef': noc,
    });
    final response = await ApiCaller.get(uri);
    if (response.statusCode != 200) {
      throw Exception(
        'BODS live feed request failed for $noc/$routeNumber: '
        'HTTP ${response.statusCode}',
      );
    }

    // Each VehicleMonitoringDelivery can contain multiple VehicleActivity
    // entries, so extract the requested values independently for every bus.
    final vehicleActivities = XmlDocument.parse(response.body)
        .findAllElements('VehicleActivity')
        .map((activity) {
          final journey = activity.getElement('MonitoredVehicleJourney');
          final location = journey?.getElement('VehicleLocation');

          String? childText(XmlElement? parent, String name) =>
              parent?.getElement(name)?.innerText.trim();

          final departureText = childText(journey, 'OriginAimedDepartureTime');
          return <String, Object?>{
            "bound": childText(journey, "DirectionRef"),
            'originRef': childText(journey, 'OriginRef'),
            'originAimedDepartureTime': departureText == null
                ? null
                : DateTime.tryParse(departureText)?.toUtc(),
            'latitude': double.tryParse(childText(location, 'Latitude') ?? ''),
            'longitude': double.tryParse(
              childText(location, 'Longitude') ?? '',
            ),
          };
        })
        // Ignore malformed activities that don't contain the journey/location
        // fields needed by the live-arrival matching logic.
        .where(
          (activity) =>
              activity['originRef'] != null &&
              activity['originAimedDepartureTime'] != null &&
              activity['latitude'] != null &&
              activity['longitude'] != null &&
              activity["bound"] != null,
        )
        .toList();

    final arrivals = <LiveEta>[];
    final ukTimezone = tz.getLocation('Europe/London');

    for (final vehicle in vehicleActivities) {
      final originRef = vehicle['originRef']! as String;
      final aimedDeparture = vehicle['originAimedDepartureTime']! as DateTime;
      final latitude = vehicle['latitude']! as double;
      final longitude = vehicle['longitude']! as double;
      final localDeparture = tz.TZDateTime.from(aimedDeparture, ukTimezone);
      final serviceDate =
          '${localDeparture.year.toString().padLeft(4, '0')}'
          '${localDeparture.month.toString().padLeft(2, '0')}'
          '${localDeparture.day.toString().padLeft(2, '0')}';
      final weekdayColumn = const [
        'monday',
        'tuesday',
        'wednesday',
        'thursday',
        'friday',
        'saturday',
        'sunday',
      ][localDeparture.weekday - 1];

      // Match the live origin/departure to an active GTFS trip that also serves
      // the requested stop. This avoids treating every trip on the line as the
      // bus's current journey.
      final tripCandidates = await db.rawQuery(
        '''
        SELECT gt.trip_id, first.departure_time
        FROM gtfs_trips gt
        INNER JOIN gtfs_routes gr ON gr.route_id = gt.route_id
        INNER JOIN gtfs_agencies ga ON ga.agency_id = gr.agency_id
        INNER JOIN gtfs_stop_times first ON first.trip_id = gt.trip_id
          AND first.stop_sequence = (
            SELECT MIN(first2.stop_sequence) FROM gtfs_stop_times first2
            WHERE first2.trip_id = gt.trip_id
          )
        WHERE gr.route_short_name = ? AND ga.agency_noc = ?
          AND first.stop_id = ?
          AND EXISTS (
            SELECT 1 FROM gtfs_stop_times target
            WHERE target.trip_id = gt.trip_id AND target.stop_id = ?
          )
          AND (
            EXISTS (
              SELECT 1 FROM gtfs_calendar gc
              WHERE gc.service_id = gt.service_id
                AND gc.start_date <= ? AND gc.end_date >= ?
                AND gc.$weekdayColumn = 1
            )
            OR EXISTS (
              SELECT 1 FROM gtfs_calendar_dates gcd
              WHERE gcd.service_id = gt.service_id
                AND gcd.date = ? AND gcd.exception_type = 1
            )
          )
          AND NOT EXISTS (
            SELECT 1 FROM gtfs_calendar_dates excluded
            WHERE excluded.service_id = gt.service_id
              AND excluded.date = ? AND excluded.exception_type = 2
          )
      ''',
        [
          routeNumber,
          noc,
          originRef,
          rawStopId,
          serviceDate,
          serviceDate,
          serviceDate,
          serviceDate,
        ],
      );
      if (tripCandidates.isEmpty) continue;

      final aimedSeconds =
          localDeparture.hour * 3600 +
          localDeparture.minute * 60 +
          localDeparture.second;
      Map<String, Object?>? selectedTrip;
      var closestDepartureDelta = double.infinity;
      for (final candidate in tripCandidates) {
        final scheduledSeconds = _gtfsTimeSeconds(candidate['departure_time']);
        if (scheduledSeconds == null) continue;
        // Compare time of day while allowing GTFS service times beyond 24:00.
        final dayOffset = (scheduledSeconds / 86400).floor();
        final candidateSeconds = scheduledSeconds - dayOffset * 86400;
        var delta = (candidateSeconds - aimedSeconds).abs();
        delta = math.min(delta, 86400 - delta);
        if (delta < closestDepartureDelta) {
          closestDepartureDelta = delta.toDouble();
          selectedTrip = candidate;
        }
      }
      // Aimed departure should identify the scheduled trip closely; reject a
      // weak match instead of reporting an ETA for the wrong journey.
      if (selectedTrip == null || closestDepartureDelta > 10 * 60) continue;

      final stopSequence = await db.rawQuery(
        '''
        SELECT st.arrival_time, st.departure_time, st.stop_id,
               st.stop_sequence, s.stop_lat, s.stop_lon
        FROM gtfs_stop_times st
        INNER JOIN gtfs_stops s ON s.stop_id = st.stop_id
        WHERE st.trip_id = ?
        ORDER BY st.stop_sequence
      ''',
        [selectedTrip['trip_id']],
      );
      final targetIndex = stopSequence.indexWhere(
        (stop) => stop['stop_id']?.toString() == rawStopId,
      );
      if (targetIndex <= 0 || stopSequence.length < 2) continue;

      // Find the consecutive stop pair whose segment is closest to the live
      // location, then interpolate the remaining time across that segment.
      var bestPairIndex = -1;
      var bestProjection = (distanceMeters: double.infinity, fraction: 0.0);
      for (var i = 0; i < stopSequence.length - 1; i++) {
        final from = stopSequence[i];
        final to = stopSequence[i + 1];
        final fromLat = (from['stop_lat'] as num?)?.toDouble();
        final fromLon = (from['stop_lon'] as num?)?.toDouble();
        final toLat = (to['stop_lat'] as num?)?.toDouble();
        final toLon = (to['stop_lon'] as num?)?.toDouble();
        if (fromLat == null ||
            fromLon == null ||
            toLat == null ||
            toLon == null) {
          continue;
        }
        final projection = _projectOntoStopPair(
          latitude,
          longitude,
          fromLat,
          fromLon,
          toLat,
          toLon,
        );
        if (projection.distanceMeters < bestProjection.distanceMeters) {
          bestProjection = projection;
          bestPairIndex = i;
        }
      }
      if (bestPairIndex < 0) continue;

      // The bus has passed the requested stop if the closest pair ends at or
      // before it in stop_sequence order.
      if (bestPairIndex >= targetIndex) continue;

      final from = stopSequence[bestPairIndex];
      final next = stopSequence[bestPairIndex + 1];
      final fromDeparture = _gtfsTimeSeconds(from['departure_time']);
      final nextArrival = _gtfsTimeSeconds(next['arrival_time']);
      final targetArrival = _gtfsTimeSeconds(
        stopSequence[targetIndex]['arrival_time'],
      );
      if (fromDeparture == null ||
          nextArrival == null ||
          targetArrival == null) {
        continue;
      }

      final pairDuration = math.max(0, nextArrival - fromDeparture).toInt();
      final fractionRemaining = (1 - bestProjection.fraction).clamp(0.0, 1.0);
      final remainingToNext = math.min(
        pairDuration,
        (fractionRemaining * pairDuration).round(),
      );
      // Add scheduled travel/dwell time from the next stop through the target.
      final afterNext = math.max(0, targetArrival - nextArrival).toInt();
      final remainingSeconds = remainingToNext + afterNext;
      arrivals.add(
        LiveEta(
          routeNumber: routeNumber,
          bound: vehicle['bound'].toString(),
          etaTime: DateTime.now().toUtc().add(
            Duration(seconds: remainingSeconds),
          ),
        ),
      );
    }

    return arrivals;
  }

  @override
  Future<bool> isStale() async {
    // gb has a centralized bus data source so this is left intentionally empty
    return false;
  }

  @override
  String get providerCode => "bods";

  @override
  String get providerName => "BODS"; // todo maybe branch display on selected route

  @override
  Future<RefreshResult> refresh({
    bool forceRefresh = false,
    ProgressCallback? onProgress,
  }) async {
    // gb has a centralized bus data source so this is left intentionally empty
    return RefreshResult();
  }
}
