import 'dart:ui';

import 'package:transport_alarm/transit/models/live_eta.dart';
import 'package:transport_alarm/transit/models/transport_stop.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/refresh_result.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/transit_provider.dart';
import 'package:transport_alarm/transit/models/transport_route.dart';

/// Static BODS timetable provider. Live ETA support can be added separately.
class UkProvider extends TransitProvider {
  @override
  String get providerCode => 'uk';

  @override
  String get providerName => 'UK Bus Data';

  @override
  Color get defaultIconColor => const Color(0xFF005EB8);

  @override
  Color get defaultTextColor => const Color(0xFFFFFFFF);

  @override
  Future<RefreshResult> refresh({
    bool forceRefresh = false,
    ProgressCallback? onProgress,
  }) async => const RefreshResult();

  @override
  Future<bool> isStale() async => false;

  /// Maps a GTFS stop and its available routes to the existing alarm config.
  Future<List<TransportStop>> fetchStopsAtGtfsStop(String gtfsStopId) async {
    final database = GtfsDatabase.forLocale('uk');
    final stop = await database.getGtfsStopById(gtfsStopId);
    if (stop == null) return const [];
    final operatorStopIds = await database.getOperatorStopIds(
      gtfsStopId,
      providerCode: providerCode,
    );
    return operatorStopIds
        .map(
          (id) => TransportStop(
            id: id,
            names: {'en': stop.name},
            lat: stop.lat,
            lng: stop.lng,
            providerCode: providerCode,
          ),
        )
        .toList();
  }

  @override
  String? alarmEtaUrl({
    required String operatorStopId,
    required TransportRoute route,
  }) {
    final routeId = _gtfsRouteId(route.id);
    if (routeId == null) return null;
    return Uri(
      scheme: 'gtfs',
      host: 'uk',
      pathSegments: [operatorStopId],
      queryParameters: {'route_id': routeId, 'direction_id': route.bound},
    ).toString();
  }

  String? _gtfsRouteId(String operatorRouteId) {
    if (!operatorRouteId.startsWith('uk:')) return null;
    final separator = operatorRouteId.lastIndexOf(':');
    if (separator <= 3) return null;
    return operatorRouteId.substring(3, separator);
  }

  @override
  Future<List<LiveEta>> fetchLiveEta(String rawStopId) async => const [];

  @override
  Future<List<LiveEta>> fetchLiveEtaForRoute(
    String rawStopId,
    String routeNumber,
  ) async => const [];
}
