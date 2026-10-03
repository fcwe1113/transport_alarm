import 'package:transport_alarm/transit/models/transport_route.dart';
import 'package:transport_alarm/transit/models/route_arrival.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';

import '../../provider_registry.dart';
import '../models/gtfs_stop.dart';
import '../models/live_eta.dart';

/// Combines matching live ETAs and scheduled departures for one GTFS stop.
Future<List<RouteArrival>> resolveArrivals({
  // todo change eta api to using stop_id and route_id instead of batching the entire stop
  required String gtfsStopId,
  String localeCode = 'hk',
  List<String>? routeNumberFilter,
  List<String>? routeProviderCodeFilter,
  int? minimumMinutesFromNow,
}) async {
  final db = GtfsDatabase.forLocale(localeCode);
  final allRoutes = await db.getRoutesForGtfsStop(gtfsStopId);
  final routes = routeNumberFilter == null
      ? allRoutes
      : allRoutes
            .where((r) => routeNumberFilter.contains(r.routeNumber))
            .toList();
  final gtfsStop = await db.getGtfsStopById(gtfsStopId);
  final liveEtas = routeNumberFilter == null
      ? (await _fetchLiveEtaForStop(
          gtfsStop!,
          localeCode,
          providerCodes: routeProviderCodeFilter,
        )).where((e) => e.etaTime != null).toList()
      : await _fetchLiveEtaForFilteredRoutes(
          gtfsStopId,
          routeNumberFilter,
          localeCode,
          providerCodes: routeProviderCodeFilter,
        );
  final scheduled = await db.getUpcomingDepartures(gtfsStopId, limit: 50);

  final routeGroups = <String, List<TransportRoute>>{};
  for (final route in routes) {
    routeGroups.putIfAbsent(route.routeNumber, () => []).add(route);
  }

  final arrivals = <RouteArrival>[];
  for (final group in routeGroups.values) {
    final representative = group.first;
    final groupProviderCodes = group.map((route) => route.providerCode).toSet();
    final matchingLive = liveEtas.where((e) {
      final minutesFromNow = e.minutesFromNow;
      return group.any((r) => e.routeNumber == r.routeNumber) &&
          (routeProviderCodeFilter == null ||
              groupProviderCodes.any(routeProviderCodeFilter.contains)) &&
          minutesFromNow != null &&
          (minimumMinutesFromNow == null ||
              minutesFromNow >= minimumMinutesFromNow);
    }).toList()..sort((a, b) => a.etaTime!.compareTo(b.etaTime!));
    if (matchingLive.isNotEmpty) {
      arrivals.add(
        RouteArrival(
          route: representative,
          minutesFromNow: matchingLive.first.minutesFromNow!,
          isLive: true,
        ),
      );
      continue;
    }

    final matchingScheduled =
        scheduled
            .where(
              (d) =>
                  group.any((r) => d.routeShortName == r.routeNumber) &&
                  (minimumMinutesFromNow == null ||
                      d.minutesFromNow >= minimumMinutesFromNow),
            )
            .toList()
          ..sort((a, b) => a.minutesFromNow.compareTo(b.minutesFromNow));
    if (matchingScheduled.isNotEmpty) {
      arrivals.add(
        RouteArrival(
          route: representative,
          minutesFromNow: matchingScheduled.first.minutesFromNow,
          isLive: false,
        ),
      );
    }
  }

  arrivals.sort((a, b) => a.minutesFromNow.compareTo(b.minutesFromNow));
  return arrivals;
}

Future<List<LiveEta>> _fetchLiveEtaForStop(
  GtfsStop stop,
  String localeCode, {
  List<String>? providerCodes,
}) async {
  final operatorStopIds = await GtfsDatabase.forLocale(localeCode)
      .getOperatorStopIds(stop.id);

  final idsByProvider = <String, List<String>>{};
  for (final operatorStopId in operatorStopIds) {
    final parts = operatorStopId.split(":");
    final providerCode = parts[0];
    final rawId = parts[1];
    if (providerCodes != null && !providerCodes.contains(providerCode)) {
      continue;
    }
    idsByProvider.putIfAbsent(providerCode, () => []).add(rawId);
  }

  final allEtas = <LiveEta>[];

  for (final entry in idsByProvider.entries) {
    final providerCode = entry.key;
    final rawIds = entry.value;
    final provider = availableProviders
        .where((p) => p.providerCode == providerCode)
        .firstOrNull;
    if (provider == null) continue; // skip stops with no valid providers
    for (final rawId in rawIds) {
      try {
        final etas = await provider.fetchLiveEta(rawId);
        allEtas.addAll(etas);
      } catch (_) {
        // do nothing
      }
    }
  }

  return allEtas;
}

Future<List<LiveEta>> _fetchLiveEtaForFilteredRoutes(
  String gtfsStopId,
  List<String> routeNumbers,
  String localeCode, {
  List<String>? providerCodes,
}) async {
  final db = GtfsDatabase.forLocale(localeCode);
  final operatorStops = await db.getOperatorStopIds(gtfsStopId);
  final results = <LiveEta>[];

  for (final operatorStopId in operatorStops) {
    final parts = operatorStopId.split(":");
    final providerCode = parts[0];
    if (providerCodes != null && !providerCodes.contains(providerCode)) {
      continue;
    }
    final rawId = parts[1];
    final provider = availableProviders
        .where((p) => p.providerCode == providerCode)
        .firstOrNull;
    if (provider == null) continue; // skip stops with no valid providers
    for (final routeNumber in routeNumbers) {
      try {
        final etas = await provider.fetchLiveEtaForRoute(rawId, routeNumber);
        results.addAll(etas.where((e) => e.etaTime != null));
      } catch (_) {
        // do nothing
      }
    }
  }

  return results;
}
