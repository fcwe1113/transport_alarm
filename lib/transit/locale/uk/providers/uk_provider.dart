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
  /// Identifies this provider in the shared transit database.
  @override
  String get providerCode => 'uk';

  /// Returns the provider name shown by the app.
  @override
  String get providerName => 'UK Bus Data';

  /// Supplies the UK provider's default icon color.
  @override
  Color get defaultIconColor => const Color(0xFF005EB8);

  /// Supplies the UK provider's default text color.
  @override
  Color get defaultTextColor => const Color(0xFFFFFFFF);

  /// Does no provider-specific refresh because timetable downloads are separate.
  @override
  Future<RefreshResult> refresh({
    bool forceRefresh = false,
    ProgressCallback? onProgress,
  }) async => const RefreshResult();

  /// Reports no provider refresh staleness; the GTFS sync provider tracks it.
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

  /// Builds the persisted reference used to look up this stop and route's schedule.
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

  /// Extracts the feed's route ID from the app's UK route identifier.
  String? _gtfsRouteId(String operatorRouteId) {
    if (!operatorRouteId.startsWith('uk:')) return null;
    final separator = operatorRouteId.lastIndexOf(':');
    if (separator <= 3) return null;
    return operatorRouteId.substring(3, separator);
  }

  /// Returns no live arrivals because this provider currently supplies schedules.
  @override
  Future<List<LiveEta>> fetchLiveEta(String rawStopId) async => const [];

  /// Returns no live route arrivals because this provider currently supplies schedules.
  @override
  Future<List<LiveEta>> fetchLiveEtaForRoute(
    String rawStopId,
    String routeNumber,
  ) async => const [];
}
