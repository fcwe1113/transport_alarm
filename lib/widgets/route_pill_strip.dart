import 'dart:async';

import 'package:transport_alarm/locale_registry.dart';
import 'package:transport_alarm/transit/models/transport_route.dart';
import 'package:transport_alarm/transit/models/gtfs_stop.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_strings.dart';

class RoutePillStrip extends StatefulWidget{
  final String gtfsStopId;
  final Map<String, Map<String, String>>? routeNumberFilter;
  final String locale;

  const RoutePillStrip ({super.key, required this.gtfsStopId, this.routeNumberFilter, required this.locale});

  @override
  State<RoutePillStrip> createState() => _RoutePillStripState();
}

class _RoutePillStripState extends State<RoutePillStrip> {
  final ScrollController _controller = ScrollController();
  Timer? _timer;
  late Future<List<TransportRoute>> _routesFuture;

  @override
  void initState() {
    super.initState();
    _routesFuture = _loadRoutes();
  }

  @override
  void didUpdateWidget(RoutePillStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gtfsStopId != widget.gtfsStopId ||
        oldWidget.locale != widget.locale) {
      _routesFuture = _loadRoutes();
    }
  }

  Future<List<TransportRoute>> _loadRoutes() =>
      GtfsDatabase.forLocale(widget.locale).getRoutesForGtfsStop(widget.gtfsStopId);

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _startAutoScroll() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 30), (_) {
      if (!_controller.hasClients) return;
      final max = _controller.position.maxScrollExtent;
      if (max <= 0) return;
      var next = _controller.offset + 0.5;
      if (next > max) next = 0;
      _controller.jumpTo(next);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(future: _routesFuture, builder: (context, snapshot) {
      final allRoutes = snapshot.data ?? [];
      final filtered = widget.routeNumberFilter == null ?  allRoutes : allRoutes.where((r) => widget.routeNumberFilter!.keys.contains(r.routeNumber)).toList();
      final routes = TransportRoute.dedupeByRouteNumber(filtered);

      if (routes.isEmpty) return const SizedBox.shrink();
      WidgetsBinding.instance.addPostFrameCallback((_) => _startAutoScroll());

      return SizedBox(height: 28, child: ListView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        children: routes.map((route) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: RoutePill(route: route),
        )).toList(),
      ),);
    });
  }
}

class RoutePill extends StatelessWidget {
  final TransportRoute route;
  const RoutePill({super.key, required this.route});

  @override
  Widget build(BuildContext context) {
    final provider = LocaleRegistry.getLocale(route.locale).transitProviders.firstWhere((p) => p.providerCode == route.providerCode);
    final colours = provider.coloursForRoute(route);
    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(color: colours.iconColour, borderRadius: BorderRadius.circular(12)),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(route.nameFor(AppStrings.languageCode), style: TextStyle(color: colours.textColour, fontSize: 11, fontWeight: FontWeight.bold,),)
        ],)
    );
  }
}
