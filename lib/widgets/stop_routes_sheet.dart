import 'dart:async';

import 'package:transport_alarm/models/scheduled_departure.dart';
import 'package:transport_alarm/provider_registry.dart';
import 'package:transport_alarm/transit/models/live_eta.dart';
import 'package:transport_alarm/transit/models/route_arrival.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:flutter/material.dart';

import '../transit/models/bus_route.dart';
import '../transit/models/gtfs_stop.dart';

class StopRoutesSheet extends StatefulWidget {
  final GtfsStop stop;
  final bool pickerMode;

  const StopRoutesSheet(
      {super.key, required this.stop, this.pickerMode = false});

  @override
  State<StopRoutesSheet> createState() => _StopRoutesSheetState();
}

class _StopRoutesSheetState extends State<StopRoutesSheet> {
  Timer? _refreshTimer;
  int _refreshTick = 0;

  @override
  void initState() {
    super.initState();
    if (!widget.pickerMode) {
      _refreshTimer = Timer.periodic(const Duration(minutes: 2), (_) {
        setState(() => _refreshTick++);
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
    if (widget.pickerMode) {
      return _buildPickerContent(context);
    } else {
      return _buildFullContent(context);
    }
  }

  Widget _buildPickerContent(BuildContext context) {
    final db = GtfsDatabase.forLocale("hk"); // todo remove locale hardcode
    return SafeArea(child: Container(
      height: MediaQuery.of(context).size.height * 0.5,
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(GtfsStop.cleanStopName(widget.stop.name), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),),
        const SizedBox(height: 12,),
        Expanded(child: FutureBuilder<List<BusRoute>>(future: db.getRoutesForGtfsStop(widget.stop.id), builder: (context, snapshot) {
          final routes = BusRoute.dedupeByRouteNumber(snapshot.data ?? []);
          if (routes.isEmpty) return const Text("No routes found for this stop");
          return Scrollbar(child: ListView(children: routes.map((r) => ListTile(
            leading: _RoutePill(route: r),
            title: Text(r.destinationText["en"] ?? ""),)).toList(),));
        },))
      ],),
    ));
  }

  Widget _buildFullContent(BuildContext context) {
    final db = GtfsDatabase.forLocale("hk"); // todo remove hardcode
    return SafeArea(child: Container(
      height: MediaQuery.of(context).size.height * 0.5,
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(GtfsStop.cleanStopName(widget.stop.name), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),), // todo check names locale
        const SizedBox(height: 12,),
        FutureBuilder(future: db.getRoutesForGtfsStop(widget.stop.id), builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const SizedBox(height: 32, child: Center(child: CircularProgressIndicator(),),);
          }
          final routes = snapshot.data ?? [];
          final dedupedRoutes = BusRoute.dedupeByRouteNumber(routes);
          if (dedupedRoutes.isEmpty) return const SizedBox.shrink();

          return SizedBox(height: 32, child: ListView(
            scrollDirection: Axis.horizontal,
            children: dedupedRoutes.map((route) => Padding(
              padding: const EdgeInsetsGeometry.only(right: 8),
              child: _RoutePill(route: route),)).toList(),
          ),);
        }),
        Expanded(
          child: FutureBuilder(
            key: ValueKey(_refreshTick),
            future: _resolveArrivals(widget.stop),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator(),);
              }
              final arrivals = snapshot.data ?? [];
              if (arrivals.isEmpty) {
                return Text("no scheduled departures found");
              }
              
              return Scrollbar(child: ListView(children: arrivals.map((a) {
                final label = a.minutesFromNow <= 0 ? "Due" : a.minutesFromNow > 60 ? "${(a.minutesFromNow / 60).toStringAsFixed(2)} hr" : "${a.minutesFromNow} min";
                return ListTile(
                  leading: _RoutePill(route: a.route),
                  title: Text(a.route.destinationText["en"] ?? ""),
                  subtitle: Text(a.isLive ? "Live" : "Scheduled"),
                  trailing: Text(label, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: a.isLive ? Colors.blueAccent : null),)
                );
              }).toList(),));
            },
          ),
        )
      ],)
    ));
  }

  Future<List<LiveEta>> _fetchLiveEtaForStop(GtfsStop stop) async {
    final operatorStopIds = await GtfsDatabase.forLocale("hk").getOperatorStopIds(stop.id); // todo fix hardcode

    final idsByProvider = <String,List<String>>{};
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
      final provider = availableProviders.where((p) => p.providerCode == providerCode).firstOrNull;
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

  Future<List<RouteArrival>> _resolveArrivals(GtfsStop stop) async {
    final db = GtfsDatabase.forLocale("hk");

    final results = await Future.wait([db.getRoutesForGtfsStop(stop.id), _fetchLiveEtaForStop(stop), db.getUpcomingDepartures(stop.id, limit: 50)]);

    final routes = results[0] as List<BusRoute>;
    final liveEtas = (results[1] as List<LiveEta>).where((e) => e.etaTime != null).toList();
    final scheduled = results[2] as List<ScheduledDeparture>;

    final routeGroups = <String, List<BusRoute>>{};
    for (final route in routes) {
      routeGroups.putIfAbsent(route.routeNumber, () => []).add(route);
    }
    final arrivals = <RouteArrival>[];

    for (final group in routeGroups.values) {
      final representative = group.first;

      final matchingLive = liveEtas.where((e) => group.any((r) => r.routeNumber == e.routeNumber)).toList()
        ..sort((a, b) => a.etaTime!.compareTo(b.etaTime!));
      if (matchingLive.isNotEmpty) {
        arrivals.add(RouteArrival(route: representative, minutesFromNow: matchingLive.first.minutesFromNow!, isLive: true));
        continue;
      }

      final matchingScheduled = scheduled.where((d) => group.any((r) => d.routeShortName == r.routeNumber)).toList()
        ..sort((a, b) => a.minutesFromNow.compareTo(b.minutesFromNow));
      if (matchingScheduled.isNotEmpty) {
        arrivals.add(RouteArrival(route: representative, minutesFromNow: matchingScheduled.first.minutesFromNow, isLive: false));
      }
    }

    arrivals.sort((a, b) => a.minutesFromNow.compareTo(b.minutesFromNow));
    return arrivals;
  }

}

class _RoutePill extends StatelessWidget {
  final BusRoute route;

  const _RoutePill({required this.route});

  @override
  Widget build(BuildContext context) {
    final provider = availableProviders.firstWhere((p) => p.providerCode == route.providerCode);
    final colours = provider.coloursForRoute(route);

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: colours.iconColour, borderRadius: BorderRadius.circular(11)),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Text(route.routeNumber, style: TextStyle(color: colours.textColour, fontWeight: FontWeight.bold, fontSize: 13),)
      ],),
    );
  }
}