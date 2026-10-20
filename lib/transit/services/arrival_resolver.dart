import 'package:transport_alarm/models/scheduled_departure.dart';
import 'package:transport_alarm/transit/models/transport_route.dart';
import 'package:transport_alarm/transit/models/route_arrival.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/locale_selection_service.dart';

import '../../locale_registry.dart';
import '../models/gtfs_stop.dart';
import '../models/live_eta.dart';

/// Drops scheduled departures for trips a live feed is already tracking,
/// including vehicles that have already passed the stop, so a bus that ran
/// early isn't still shown as due on the timetable.
List<ScheduledDeparture> withoutLiveTrips(
  List<ScheduledDeparture> scheduled,
  Iterable<LiveEta> liveEtas,
) {
  final liveTripIds = liveEtas.map((e) => e.tripId).whereType<String>().toSet();
  if (liveTripIds.isEmpty) return scheduled;
  return scheduled.where((d) => !liveTripIds.contains(d.tripId)).toList();
}

/// Each route's next arrival at [gtfsStopId]: the soonest live prediction,
/// or failing that the soonest timetabled departure not already being
/// tracked live. With [routeNumberFilter], only those routes, and only live
/// buses heading to each route's saved destination. [minimumMinutesFromNow]
/// skips arrivals sooner than that.
Future<List<RouteArrival>> resolveArrivals({
  required String gtfsStopId,
  Map<String, Map<String, String>>? routeNumberFilter,
  int? minimumMinutesFromNow,
  required String locale,
  // Called for each live request that fails, so callers can tell a failed
  // feed from one that's simply tracking no bus. Failures are otherwise
  // skipped, leaving the timetable to fill in.
  void Function()? onLiveFetchFailed,
}) async {
  final db = GtfsDatabase.forLocale(locale);
  final allRoutes = await db.getRoutesForGtfsStop(gtfsStopId);
  final routes = routeNumberFilter == null
      ? allRoutes
      : allRoutes
            .where((r) => routeNumberFilter.keys.contains(r.routeNumber))
            .toList();
  final gtfsStop = await db.getGtfsStopById(gtfsStopId);
  final allLiveEtas = routeNumberFilter == null
      ? await _fetchLiveEtaForStop(gtfsStop!, locale, onLiveFetchFailed)
      : await _fetchLiveEtaForFilteredRoutes(
          gtfsStop!,
          routeNumberFilter,
          onLiveFetchFailed,
        );
  final liveEtas = allLiveEtas.where((e) => e.etaTime != null).toList();
  final scheduled = withoutLiveTrips(
    await db.getUpcomingDepartures(gtfsStopId, limit: 50),
    allLiveEtas,
  );

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
          destination: matchingLive.first.destination,
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
          destination: matchingScheduled.first.destination,
          isLive: false,
        ),
      );
    }
  }

  arrivals.sort((a, b) => a.minutesFromNow.compareTo(b.minutesFromNow));
  return arrivals;
}

/// Splits a saved "provider:id" operator stop ID; null if it isn't one.
({String providerCode, String rawId})? _splitOperatorStopId(String operatorStopId) {
  final separator = operatorStopId.indexOf(":");
  if (separator <= 0) return null;
  return (
    providerCode: operatorStopId.substring(0, separator),
    rawId: operatorStopId.substring(separator + 1),
  );
}

/// Every live arrival at [stop] from each provider serving it.
Future<List<LiveEta>> _fetchLiveEtaForStop(
  GtfsStop stop,
  String locale, [
  void Function()? onFailed,
]) async {
  final operatorStopIds = await GtfsDatabase.forLocale(locale).getOperatorStopIds(stop.id);

  final allEtas = <LiveEta>[];
  for (final operatorStopId in operatorStopIds) {
    final parts = _splitOperatorStopId(operatorStopId);
    if (parts == null) continue;
    final provider = LocaleRegistry.provider(stop.locale, parts.providerCode);
    if (provider == null) continue;
    try {
      allEtas.addAll(await provider.fetchLiveEta(parts.rawId));
    } catch (_) {
      onFailed?.call();
    }
  }
  return allEtas;
}

/// Live arrivals at [stop] for the routes in [routeNumbers], keeping only
/// buses heading to each route's saved destination.
Future<List<LiveEta>> _fetchLiveEtaForFilteredRoutes(
  GtfsStop stop,
  Map<String, Map<String, String>> routeNumbers, [
  void Function()? onFailed,
]) async {
  final db = GtfsDatabase.forLocale(stop.locale);
  final operatorStops = await db.getOperatorStopIds(stop.id);
  final currentLang = await LocaleSelectionService().getAppLanguageCode();
  final results = <LiveEta>[];

  for (final operatorStopId in operatorStops) {
    final parts = _splitOperatorStopId(operatorStopId);
    if (parts == null) continue;
    final provider = LocaleRegistry.provider(stop.locale, parts.providerCode);
    if (provider == null) continue;
    for (final routeNumber in routeNumbers.entries) {
      try {
        final etas = await provider.fetchLiveEtaForRoute(parts.rawId, routeNumber.key);
        // Compare both sides in the same language, so a name only the live
        // data has (e.g. zh-Hans) can't be compared against an English one,
        // and with the provider's own cleanup applied to the live name.
        final key = routeNumber.value.containsKey(currentLang) ? currentLang : "en";
        final savedDestination = routeNumber.value[key];
        results.addAll(etas.where((e) {
          final liveDestination = e.destination[key];
          return savedDestination != null &&
              liveDestination != null &&
              provider.destinationMatches(
                savedDestination,
                provider.cleanDestination(liveDestination),
                rawStopId: parts.rawId,
              );
        }));
      } catch (_) {
        onFailed?.call();
      }
    }
  }

  return results;
}
