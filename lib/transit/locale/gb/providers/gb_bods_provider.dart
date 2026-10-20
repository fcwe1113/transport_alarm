import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:transport_alarm/locale_registry.dart';
import 'package:transport_alarm/transit/models/live_eta.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/refresh_result.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/transit_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:timezone/timezone.dart' as tz;
import 'package:xml/xml.dart';

import '../../../models/route_colour_scheme.dart';
import '../../../models/transport_route.dart';

/// GB live buses: the BODS SIRI-VM vehicle feed, with each vehicle matched
/// to its GTFS trip and its position turned into an ETA; London stops use
/// TfL's arrivals API instead. Timetables come from GbGtfsSyncProvider, so
/// there's nothing to refresh here.
class GbBodsProvider extends TransitProvider {
  static String? _cachedApiKey;

  final GtfsDatabase db = LocaleRegistry.getLocale("gb").db;

  /// London stops' ATCO codes start with this; TfL's API covers them.
  static const _londonStopPrefix = "490";

  // Compiled in at build time rather than bundled as a readable asset:
  // flutter run/build --dart-define-from-file=config/build_secrets.json,
  // and --obfuscate for release builds. Still extractable from the binary
  // with effort, so keep request volume low and rotate it if it leaks.
  static const _buildApiKey = String.fromEnvironment('UK_BODS_KEY');

  /// Loads the build-time key once during startup so synchronous URL
  /// builders can use it.
  static Future<void> loadApiKey() async {
    final key = _buildApiKey.trim();
    _cachedApiKey = key.isEmpty ? null : key;
  }

  // One operator and route's live vehicle feed is shared for this long by
  // every lookup in this isolate (alarm checks, stop sheets, alarm cards),
  // to keep requests on the shared key down.
  static const _feedCacheAge = Duration(seconds: 30);
  static final _feedCache = <String, ({DateTime fetchedAt, Future<String> xml})>{};

  /// The SIRI-VM vehicle feed for [routeNumber] run by [noc], from the cache
  /// when it's under [_feedCacheAge] old. A request still in flight is
  /// shared too, and a failed one isn't cached.
  Future<String> _vehicleFeed(String noc, String routeNumber, String apiKey) {
    final key = '$noc|$routeNumber';
    final cached = _feedCache[key];
    if (cached != null &&
        DateTime.now().difference(cached.fetchedAt) < _feedCacheAge) {
      return cached.xml;
    }
    final xml = _requestVehicleFeed(noc, routeNumber, apiKey);
    _feedCache[key] = (fetchedAt: DateTime.now(), xml: xml);
    xml.then<void>((_) {}, onError: (_) {
      if (identical(_feedCache[key]?.xml, xml)) _feedCache.remove(key);
    });
    return xml;
  }

  // Shared through preferences, so the app and the background alarm
  // isolate both respect a pause.
  static const _pausedUntilKey = 'bods_requests_paused_until';

  /// How long to stop calling BODS after it refuses a request: an hour if
  /// the key was rejected (401/403), or the server's Retry-After (5 minutes
  /// if it gives none) when rate limited (429). Null for other failures.
  static Duration? _pauseFor(http.Response response) {
    switch (response.statusCode) {
      case 401:
      case 403:
        return const Duration(hours: 1);
      case 429:
        final retryAfter = int.tryParse(response.headers['retry-after'] ?? '');
        if (retryAfter == null) return const Duration(minutes: 5);
        return Duration(seconds: retryAfter.clamp(30, 3600));
      default:
        return null;
    }
  }

  Future<String> _requestVehicleFeed(
    String noc,
    String routeNumber,
    String apiKey,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    // Pick up a pause set by the other isolate.
    await prefs.reload();
    final pausedUntil = prefs.getInt(_pausedUntilKey);
    if (pausedUntil != null &&
        DateTime.now().millisecondsSinceEpoch < pausedUntil) {
      throw StateError(
        'BODS requests are paused until '
        '${DateTime.fromMillisecondsSinceEpoch(pausedUntil)} after the '
        'service refused a request.',
      );
    }

    final uri = Uri.https('data.bus-data.dft.gov.uk', '/api/v1/datafeed/', {
      'api_key': apiKey,
      'lineRef': routeNumber,
      'operatorRef': noc,
    });
    final response = await ApiCaller.get(uri);
    final pause = _pauseFor(response);
    if (pause != null) {
      await prefs.setInt(
        _pausedUntilKey,
        DateTime.now().add(pause).millisecondsSinceEpoch,
      );
    }
    if (response.statusCode != 200) {
      throw Exception(
        'BODS live feed request failed for $noc/$routeNumber: '
        'HTTP ${response.statusCode}',
      );
    }
    return response.body;
  }

  /// Returns the key loaded by [loadApiKey].
  String? _apiKey() => _cachedApiKey;

  /// BODS live data uses underscores in place of spaces in destination names.
  @override
  String cleanDestination(String destination) =>
      destination.replaceAll("_", " ").replaceAll(RegExp(r"\s+"), " ").trim();

  @override
  RouteColourScheme coloursForRoute(TransportRoute route) {
    switch (route.agency) {
      case "Bee Network":
        return const RouteColourScheme(
          iconColour: Colors.yellow,
          textColour: Colors.black,
        );
      case "Arriva London North":
      case "Arriva London South":
      case "London Transit": // todo i am not sure should this be here
      case "London United":
      case "London Sovereign":
      case "Stagecoach London":
      case "Go Ahead London":
      case "Arriva London":
        return const RouteColourScheme(
          iconColour: Colors.red,
          textColour: Colors.white,
        );
      case "Stagecoach East":
      case "Stagecoach East Midlands":
      case "Stagecoach South":
      case "Stagecoach Yorkshire":
      case "Stagecoach South Wales":
      case "Stagecoach North East":
      case "Stagecoach Merseyside and South Lancashire":
      case "Stagecoach South East":
      case "Stagecoach Midlands":
      case "Stagecoach Bluebird":
      case "Stagecoach West Scotland":
      case "Stagecoach Cumbria and North Lancashire":
      case "Stagecoach East Scotland":
      case "Stagecoach South West":
      case "Stagecoach West":
      case "Stagecoach Oxfordshire":
        return const RouteColourScheme(
          iconColour: Colors.lightBlue,
          textColour: Color(0xFFFFA600),
        );
      case "First South Yorkshire":
      case "First South & West Wales":
      case "First Leicester":
      case "First Halifax":
      case "First Halifax, Calder Valley & Huddersfield":
      case "First Berkshire & The Thames Valley":
      case "First Essex":
      case "First Aberdeen":
      case "First Norfolk & Suffolk":
      case "First York":
      case "First Bristol, Bath & the West":
      case "First Buses of Somerset":
      case "First Wessex, Dorset & South Somerset":
      case "First Portsmouth, Fareham & Gosport":
      case "First Potteries":
      case "First Leeds":
      case "First Bradford":
      case "First Worcestershire":
        return const RouteColourScheme(
          iconColour: Color(0xFF290169),
          textColour: Color(0xFFDA00FF),
        );
      case "National Express West Midlands":
        return const RouteColourScheme(
          iconColour: Colors.white24,
          textColour: Colors.red,
        );
      case "Arriva Midlands":
      case "Arriva North East":
      case "Fasttrack (Arriva Kent Thameside)":
      case "Arriva Derby":
      case "Arriva North West":
      case "Arriva Kent and Surrey":
      case "Arriva Herts and Essex":
      case "Arriva Beds and Bucks":
      case "Arriva Wales":
      case "Arriva YorkShire":
        return const RouteColourScheme(
          iconColour: Color(0xFF00C8FF),
          textColour: Colors.white,
        );
      // todo add more colors if i hv time
    }

    return super.coloursForRoute(route);
  }

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
    if (rawStopId.startsWith(_londonStopPrefix)) {
      return _fetchTflArrivals(
        Uri.parse("https://api.tfl.gov.uk/StopPoint/$rawStopId/Arrivals"),
        'stop_id $rawStopId',
      );
    } else {
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
  }

  /// Arrivals from a TfL arrivals endpoint, a JSON list of predictions.
  /// [description] names the request in errors.
  Future<List<LiveEta>> _fetchTflArrivals(Uri url, String description) async {
    final response = await ApiCaller.get(url);
    if (response.statusCode != 200) {
      throw Exception(
        'TfL live feed request failed for $description: HTTP ${response.statusCode}',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! List) {
      throw const FormatException('TfL arrivals response must be a JSON list.');
    }
    final now = DateTime.now().toUtc();
    return decoded.whereType<Map<String, dynamic>>().map<LiveEta>((entry) {
      final timeToStation = (entry['timeToStation'] as num?)?.round();
      return LiveEta(
        routeNumber: entry['lineName']?.toString() ?? '',
        bound: entry['direction']?.toString() ?? '',
        destination: {"en": cleanDestination(entry["destinationName"]?.toString() ?? "")},
        etaTime: timeToStation == null
            ? null
            : now.add(Duration(seconds: timeToStation)),
      );
    }).toList();
  }

  /// Live ETAs for one route at a GB stop. Outside London: fetches the
  /// route's vehicles from BODS, matches each to the GTFS trip with its
  /// origin and aimed departure, finds the stop pair it's between, and adds
  /// the timetabled time left to the stop. A vehicle already past the stop
  /// is returned with [LiveEta.hasPassed].
  @override
  Future<List<LiveEta>> fetchLiveEtaForRoute(
    String rawStopId,
    String routeNumber,
  ) async {
    if (rawStopId.startsWith(_londonStopPrefix)) {
      // todo check functionality
      return _fetchTflArrivals(
        Uri.parse("https://api.tfl.gov.uk/Line/$routeNumber/Arrivals/$rawStopId"),
        'route name $routeNumber at stop_id $rawStopId',
      );
    } else {
      final db = await this.db.database;
      final nocRows = await db.rawQuery(
        '''
        SELECT DISTINCT ga.agency_noc
        FROM gtfs_stops gs
        INNER JOIN gtfs_stop_times gst ON gs.stop_id = gst.stop_id
        INNER JOIN gtfs_trips gt ON gst.trip_id = gt.trip_id
        INNER JOIN gtfs_routes gr ON gt.route_id = gr.route_id
        INNER JOIN gtfs_agencies ga ON gr.agency_id = ga.agency_id
        WHERE gs.stop_id = ? AND gr.route_short_name = ?
        LIMIT 1
        ''',
        [rawStopId, routeNumber],
      );
      final noc = nocRows.isEmpty
          ? null
          : nocRows.first['agency_noc']?.toString();
      if (noc == null || noc.isEmpty) {
        throw StateError(
          'No operator NOC found for $routeNumber at $rawStopId.',
        );
      }
      final apiKey = _apiKey();
      if (apiKey == null || apiKey.isEmpty) {
        throw StateError('BODS API key has not been loaded.');
      }

      final feedXml = await _vehicleFeed(noc, routeNumber, apiKey);

      // Each VehicleMonitoringDelivery can contain multiple VehicleActivity
      // entries, so extract the requested values independently for every bus.
      final vehicleActivities = XmlDocument.parse(feedXml)
          .findAllElements('VehicleActivity')
          .map((activity) {
            final journey = activity.getElement('MonitoredVehicleJourney');
            final location = journey?.getElement('VehicleLocation');

            String? childText(XmlElement? parent, String name) =>
                parent?.getElement(name)?.innerText.trim();

            final departureText = childText(
              journey,
              'OriginAimedDepartureTime',
            );
            return <String, Object?>{
              "bound": childText(journey, "DirectionRef"),
              'originRef': childText(journey, 'OriginRef'),
              'originAimedDepartureTime': departureText == null
                  ? null
                  : DateTime.tryParse(departureText)?.toUtc(),
              "destinationName": childText(journey, "DestinationName"),
              'latitude': double.tryParse(
                childText(location, 'Latitude') ?? '',
              ),
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
          ).toList();

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
        // No timetabled trip matches this vehicle's journey.
        if (tripCandidates.isEmpty) continue;

        final aimedSeconds =
            localDeparture.hour * 3600 +
            localDeparture.minute * 60 +
            localDeparture.second;
        Map<String, Object?>? selectedTrip;
        var closestDepartureDelta = double.infinity;
        for (final candidate in tripCandidates) {
          final scheduledSeconds = _gtfsTimeSeconds(
            candidate['departure_time'],
          );
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

        final tripId = selectedTrip['trip_id']?.toString();
        final destination = {
          "en": cleanDestination(vehicle["destinationName"]?.toString() ?? ""),
        };

        // The bus has passed the requested stop if the closest pair ends at or
        // before it in stop_sequence order. Report it as passed so callers can
        // drop that trip's scheduled arrival instead of showing a gone bus.
        if (bestPairIndex >= targetIndex) {
          arrivals.add(
            LiveEta(
              routeNumber: routeNumber,
              bound: vehicle['bound'].toString(),
              destination: destination,
              tripId: tripId,
              hasPassed: true,
            ),
          );
          continue;
        }

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
            destination: destination,
            etaTime: DateTime.now().toUtc().add(
              Duration(seconds: remainingSeconds),
            ),
            tripId: tripId,
          ),
        );
      }

      return arrivals;
    }
  }

  /// GB routes and stops come from the GTFS import, so there's nothing of
  /// this provider's own to go stale.
  @override
  Future<bool> isStale() async => false;

  @override
  String get providerCode => "bods";

  @override
  String get providerName => "BODS"; // todo maybe branch display on selected route

  @override
  Future<RefreshResult> refresh({
    bool forceRefresh = false,
    ProgressCallback? onProgress,
  }) async {
    // See isStale: the GTFS import covers GB.
    return const RefreshResult();
  }

  @override
  String? alarmEtaUrl({
    required String operatorStopId,
    required TransportRoute route,
  }) {
    if (operatorStopId.startsWith(_londonStopPrefix)) {
      return "https://api.tfl.gov.uk/Line/${route.routeNumber}/Arrivals/$operatorStopId";
    } else {
      final noc = getRouteNoc(route);
      if (noc == null || noc.isEmpty) return null;
      final apiKey = _apiKey();
      if (apiKey == null || apiKey.isEmpty) return null;

      return Uri.https('data.bus-data.dft.gov.uk', '/api/v1/datafeed/', {
        'api_key': apiKey,
        'lineRef': route.routeNumber,
        'operatorRef': noc,
      }).toString();
    }
  }

  /// Returns the NOC already loaded onto a route by the GTFS route query.
  String? getRouteNoc(TransportRoute route) => route.agencyNoc;
}
