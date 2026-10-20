import 'dart:async';

import 'package:transport_alarm/models/scheduled_departure.dart';
import 'package:transport_alarm/transit/models/live_eta.dart';
import 'package:transport_alarm/transit/models/route_arrival.dart';
import 'package:transport_alarm/transit/services/arrival_resolver.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_strings.dart';

import '../locale_registry.dart';
import '../transit/models/route_colour_scheme.dart';
import '../transit/models/transport_route.dart';
import '../transit/models/gtfs_stop.dart';
import '../transit/transit_provider.dart';

/// The provider [providerCode] in [locale], or null when this build doesn't
/// know the locale or provider.
TransitProvider? _providerFor(String locale, String providerCode) =>
    LocaleRegistry.getLocales([locale]).firstOrNull?.transitProviders
        .where((p) => p.providerCode == providerCode)
        .firstOrNull;

/// A map stop's bottom sheet. Normally it shows the stop's routes and its
/// next arrivals, refreshed every 2 minutes and filtered by tapping a route.
/// In [pickerMode], for choosing an alarm's stop, it lists the routes only.
class StopRoutesSheet extends StatefulWidget {
  final GtfsStop stop;
  final bool pickerMode;

  const StopRoutesSheet({
    super.key,
    required this.stop,
    this.pickerMode = false,
  });

  @override
  State<StopRoutesSheet> createState() => _StopRoutesSheetState();
}

class _StopRoutesSheetState extends State<StopRoutesSheet> {
  Timer? _refreshTimer;
  // Bumped every 2 minutes to reload the arrivals.
  int _refreshTick = 0;
  // The route the arrivals are filtered to, or null for every route.
  String? _selectedRouteNumber;
  late Future<List<TransportRoute>> _routesFuture;
  // Kept between builds, so only a tick or a new route filter fetches live
  // arrivals again, not every rebuild.
  Future<List<RouteArrival>>? _arrivalsFuture;

  void _toggleRouteSelection(TransportRoute route) {
    setState(() {
      _selectedRouteNumber = _selectedRouteNumber == route.routeNumber
          ? null
          : route.routeNumber;
      _arrivalsFuture = null;
    });
  }

  @override
  void initState() {
    super.initState();
    _routesFuture = GtfsDatabase.forLocale(widget.stop.locale).getRoutesForGtfsStop(widget.stop.id);
    if (!widget.pickerMode) {
      _refreshTimer = Timer.periodic(const Duration(minutes: 2), (_) {
        setState(() {
          _refreshTick++;
          _arrivalsFuture = null;
        });
      });
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Half the screen: the map keeps the stop centred above it.
    return SafeArea(
      child: Container(
        height: MediaQuery.of(context).size.height * 0.5,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.stop.displayNameFor(AppStrings.languageCode),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            if (widget.pickerMode)
              Expanded(child: _buildPickerRoutes())
            else ...[
              _buildRouteStrip(),
              const SizedBox(height: 4),
              Expanded(child: _buildArrivals()),
            ],
          ],
        ),
      ),
    );
  }

  /// Picker mode's list of the stop's routes and their destinations.
  Widget _buildPickerRoutes() {
    return FutureBuilder<List<TransportRoute>>(
      future: _routesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 32,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final routes = TransportRoute.dedupeByRouteNumber(
          snapshot.data ?? [],
        );
        if (routes.isEmpty) {
          return Text(AppStrings.text('stop.no_routes'));
        }
        return Scrollbar(
          child: ListView(
            children: routes
                .map(
                  (r) => ListTile(
                    // Sized to its label: a ListTile's leading
                    // widget can't fill the tile's width.
                    leading: _RoutePill(
                      route: r,
                      selected: _selectedRouteNumber == r.routeNumber,
                      onTap: () => _toggleRouteSelection(r),
                      fitContent: true,
                    ),
                    title: Text(
                      r.destinationNameFor(AppStrings.languageCode),
                    ),
                  ),
                )
                .toList(),
          ),
        );
      },
    );
  }

  /// A row of the stop's routes; tapping one filters the arrivals to it.
  Widget _buildRouteStrip() {
    return FutureBuilder(
      future: _routesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 32,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final routes = snapshot.data ?? [];
        final dedupedRoutes = TransportRoute.dedupeByRouteNumber(
          routes,
        );
        if (dedupedRoutes.isEmpty) return const SizedBox.shrink();

        return SizedBox(
          height: 32,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: dedupedRoutes
                .map(
                  (route) => Padding(
                    padding: const EdgeInsetsGeometry.only(right: 8),
                    child: _RoutePill(
                      route: route,
                      selected:
                          _selectedRouteNumber == route.routeNumber,
                      onTap: () => _toggleRouteSelection(route),
                    ),
                  ),
                )
                .toList(),
          ),
        );
      },
    );
  }

  /// The next arrival of each route, or every arrival of the selected route.
  Widget _buildArrivals() {
    return FutureBuilder(
      key: ValueKey(_refreshTick),
      future: _arrivalsFuture ??= _resolveArrivals(widget.stop, routeNumber: _selectedRouteNumber),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          // todo implement seamless background load
          return const Center(child: CircularProgressIndicator());
        }
        final arrivals = snapshot.data ?? [];
        if (arrivals.isEmpty) {
          return Text(AppStrings.text('stop.no_departures'));
        }

        return Scrollbar(
          child: ListView(
            children: arrivals.map((a) {
              return ListTile(
                leading: _RoutePill(
                  route: a.route,
                  selected:
                      _selectedRouteNumber == a.route.routeNumber,
                  fitContent: true,
                ),
                title: Text(
                  _arrivalDestination(a),
                ),
                subtitle: Text(
                  AppStrings.text(
                    a.isLive ? 'stop.live' : 'stop.scheduled',
                  ),
                ),
                trailing: Text(
                  _arrivalLabel(a.minutesFromNow),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: a.isLive ? Colors.blueAccent : null,
                  ),
                ),
              );
            }).toList(),
          ),
        );
      },
    );
  }

  String _arrivalLabel(int minutesFromNow) {
    if (minutesFromNow <= 0) return AppStrings.text('stop.due');
    if (minutesFromNow > 60) {
      return AppStrings.text('stop.hours', {'hours': (minutesFromNow / 60).toStringAsFixed(2)});
    }
    return AppStrings.text('stop.minutes', {'minutes': minutesFromNow});
  }

  /// Live ETAs at [stop] from every provider that serves it. A provider
  /// whose request fails is left out, so the rest still show.
  Future<List<LiveEta>> _fetchLiveEtaForStop(GtfsStop stop) async {
    final operatorStopIds = await LocaleRegistry.getLocale(stop.locale).db
        .getOperatorStopIds(stop.id);

    // Operator stop IDs are saved as "provider:id".
    final idsByProvider = <String, List<String>>{};
    for (final operatorStopId in operatorStopIds) {
      final separator = operatorStopId.indexOf(":");
      if (separator <= 0) continue;
      idsByProvider
          .putIfAbsent(operatorStopId.substring(0, separator), () => [])
          .add(operatorStopId.substring(separator + 1));
    }

    final allEtas = <LiveEta>[];

    for (final entry in idsByProvider.entries) {
      final providerCode = entry.key;
      final rawIds = entry.value;
      final provider = _providerFor(stop.locale, providerCode);
      if (provider == null) continue;
      for (final rawId in rawIds) {
        try {
          allEtas.addAll(await provider.fetchLiveEta(rawId));
        } catch (_) {
          // Shown from the timetable instead.
        }
      }
    }

    return allEtas;
  }

  /// The arrival's own destination in the app language, or the route's
  /// destination when it has none, cleaned by the route's provider.
  String _arrivalDestination(RouteArrival arrival) {
    final languageCode = AppStrings.languageCode;
    final destination = arrival.destination[languageCode] ??
        arrival.route.destinationNameFor(languageCode);
    final provider = _providerFor(arrival.route.locale, arrival.route.providerCode);
    return provider?.cleanDestination(destination) ?? destination;
  }

  /// Each route's next arrival at [stop], live where available and from the
  /// timetable otherwise. With [routeNumber], every live arrival of that
  /// route instead.
  Future<List<RouteArrival>> _resolveArrivals(GtfsStop stop, {String? routeNumber}) async {
    final db = GtfsDatabase.forLocale(stop.locale);

    final results = await Future.wait([
      db.getRoutesForGtfsStop(stop.id),
      _fetchLiveEtaForStop(stop),
      db.getUpcomingDepartures(stop.id, limit: 50),
    ]);

    final routes = results[0] as List<TransportRoute>;
    final allLiveEtas = results[1] as List<LiveEta>;
    final liveEtas = allLiveEtas.where((e) => e.etaTime != null).toList();
    final scheduled = withoutLiveTrips(
      results[2] as List<ScheduledDeparture>,
      allLiveEtas,
    );

    final routeGroups = <String, List<TransportRoute>>{};
    for (final route in routes) {
      routeGroups.putIfAbsent(route.routeNumber, () => []).add(route);
    }
    final arrivals = <RouteArrival>[];

    for (final group in routeGroups.values) {
      final representative = group.first;
      if (routeNumber != null && routeNumber != representative.routeNumber) continue;

      final matchingLive =
          liveEtas
              .where((e) => group.any((r) => r.routeNumber == e.routeNumber))
              .toList()
            ..sort((a, b) => a.etaTime!.compareTo(b.etaTime!));
      if (matchingLive.isNotEmpty) {
        if (routeNumber == null) {
          arrivals.add(
            RouteArrival(
              route: representative,
              destination: matchingLive.first.destination,
              minutesFromNow: matchingLive.first.minutesFromNow!,
              isLive: true,
            ),
          );
        } else {
          arrivals.addAll(matchingLive.map((a) => RouteArrival(
              route: representative,
              destination: a.destination,
              minutesFromNow: a.minutesFromNow!,
              isLive: true
          )));
        }
        continue;
      }

      final matchingScheduled =
          scheduled
              .where((d) => group.any((r) => d.routeShortName == r.routeNumber))
              .toList()
            ..sort((a, b) => a.minutesFromNow.compareTo(b.minutesFromNow));
      if (matchingScheduled.isNotEmpty) {
        arrivals.add(
          RouteArrival(
            route: representative,
            destination: matchingScheduled.first.destination,
            minutesFromNow: matchingScheduled.first.minutesFromNow,
            isLive: false,
          ),
        );
      }
    }

    arrivals.sort((a, b) => a.minutesFromNow.compareTo(b.minutesFromNow));
    return arrivals;
  }
}

/// A tappable route pill, outlined when it's the selected route.
class _RoutePill extends StatelessWidget {
  final TransportRoute route;
  final bool selected;
  final VoidCallback? onTap;
  /// Sizes the pill to its label, for use as a ListTile's leading widget,
  /// which can't fill the tile's width.
  final bool fitContent;

  const _RoutePill({
    required this.route,
    this.selected = false,
    this.onTap,
    this.fitContent = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colours = _providerFor(route.locale, route.providerCode)?.coloursForRoute(route) ??
        RouteColourScheme(iconColour: scheme.secondaryContainer, textColour: scheme.onSecondaryContainer);

    return Material(
      color: colours.iconColour,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: selected
                ? Border.all(color: colours.textColour, width: 2)
                : null,
            borderRadius: BorderRadius.circular(11),
          ),
          alignment: fitContent ? null : Alignment.center,
          child: fitContent
              ? Center(widthFactor: 1, child: _label(colours.textColour))
              : _label(colours.textColour),
        ),
      ),
    );
  }

  Widget _label(Color textColour) {
    return Text(
      route.nameFor(AppStrings.languageCode),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: textColour,
        fontWeight: FontWeight.bold,
        fontSize: 13,
      ),
    );
  }
}
