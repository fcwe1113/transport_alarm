import 'package:transport_alarm/models/scheduled_departure.dart';
import 'package:transport_alarm/transit/models/transport_route.dart';
import 'package:transport_alarm/transit/models/route_arrival.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';

import '../../locale_registry.dart';
import '../models/gtfs_stop.dart';
import '../models/live_eta.dart';

Future<List<RouteArrival>> resolveArrivals({
  required String gtfsStopId,
  List<String>? routeNumberFilter,
  int? minimumMinutesFromNow,
  required String locale,
}) async {
  final db = GtfsDatabase.forLocale(locale);
  final allRoutes = await db.getRoutesForGtfsStop(gtfsStopId);
  final routes = routeNumberFilter == null
      ? allRoutes
      : allRoutes
            .where((r) => routeNumberFilter.contains(r.routeNumber))
            .toList();
  final gtfsStop = await db.getGtfsStopById(gtfsStopId);
  final liveEtas = routeNumberFilter == null
      ? (await _fetchLiveEtaForStop(gtfsStop!, locale))
            .where((e) => e.etaTime != null)
            .toList()
      : await _fetchLiveEtaForFilteredRoutes(gtfsStop!, routeNumberFilter);
  final scheduled = await db.getUpcomingDepartures(gtfsStopId, limit: 50);

  final routeGroups = <String, List<TransportRoute>>{};
  for (final route in routes) {
    routeGroups.putIfAbsent(route.routeNumber, () => []).add(route);
  }

  final arrivals = <RouteArrival>[];
  for (final group in routeGroups.values) {
    final representative = group.first;
    final matchingLive = liveEtas.where((e) {
      final minutesFromNow = e.minutesFromNow;
      return group.any((r) => e.routeNumber == r.routeNumber) &&
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

Future<List<LiveEta>> _fetchLiveEtaForStop(GtfsStop stop, String locale) async {
  final operatorStopIds = await GtfsDatabase.forLocale(locale).getOperatorStopIds(stop.id);

  final idsByProvider = <String, List<String>>{};
  for (final operatorStopId in operatorStopIds) {
    final parts = operatorStopId.split(":");
    final providerCode = parts[0];
    final rawId = parts[1];
    idsByProvider.putIfAbsent(providerCode, () => []).add(rawId);
  }

  final allEtas = <LiveEta>[];

  for (final entry in idsByProvider.entries) {
    final providerCode = entry.key;
    final rawIds = entry.value;
    final provider = LocaleRegistry.getLocale(stop.locale).transitProviders
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
  GtfsStop stop,
  List<String> routeNumbers,
) async {
  final db = GtfsDatabase.forLocale(stop.locale);
  final operatorStops = await db.getOperatorStopIds(stop.id);
  final results = <LiveEta>[];

  for (final operatorStopId in operatorStops) {
    final parts = operatorStopId.split(":");
    final providerCode = parts[0];
    final rawId = parts[1];
    final provider = LocaleRegistry.getLocale(stop.locale).transitProviders
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
