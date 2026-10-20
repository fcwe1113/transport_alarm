import 'dart:async';

import 'package:transport_alarm/locale_registry.dart';
import 'package:transport_alarm/transit/models/route_colour_scheme.dart';
import 'package:transport_alarm/transit/models/transport_route.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:flutter/material.dart';
import 'package:transport_alarm/l10n/app_strings.dart';

/// A single row of route pills for a stop, scrolling slowly sideways when
/// they don't all fit.
class RoutePillStrip extends StatefulWidget {
  final String gtfsStopId;
  /// Only these route numbers (the keys) are shown; null shows every route.
  final Map<String, Map<String, String>>? routeNumberFilter;
  final String locale;

  const RoutePillStrip({super.key, required this.gtfsStopId, this.routeNumberFilter, required this.locale});

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

  /// Scrolls the strip half a pixel every 30ms, jumping back to the start
  /// at the end, but only while the pills overflow it. A strip that fits
  /// runs no timer.
  void _updateAutoScroll() {
    if (!mounted || !_controller.hasClients) return;
    if (_controller.position.maxScrollExtent <= 0) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (_timer?.isActive ?? false) return;
    _timer = Timer.periodic(const Duration(milliseconds: 30), (_) {
      if (!_controller.hasClients) return;
      final max = _controller.position.maxScrollExtent;
      if (max <= 0) {
        _timer?.cancel();
        _timer = null;
        return;
      }
      var next = _controller.offset + 0.5;
      if (next > max) next = 0;
      _controller.jumpTo(next);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(future: _routesFuture, builder: (context, snapshot) {
      final allRoutes = snapshot.data ?? [];
      final filter = widget.routeNumberFilter;
      final filtered = filter == null ? allRoutes : allRoutes.where((r) => filter.containsKey(r.routeNumber)).toList();
      final routes = TransportRoute.dedupeByRouteNumber(filtered);

      if (routes.isEmpty) return const SizedBox.shrink();
      // After layout, once the strip's overflow is known.
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateAutoScroll());

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

/// A route's name on a pill in its operator's colours.
class RoutePill extends StatelessWidget {
  final TransportRoute route;
  const RoutePill({super.key, required this.route});

  @override
  Widget build(BuildContext context) {
    // A route whose locale or provider this build doesn't know, such as one
    // from data saved by an older version, gets theme colours instead.
    final provider = LocaleRegistry.provider(route.locale, route.providerCode);
    final scheme = Theme.of(context).colorScheme;
    final colours = provider?.coloursForRoute(route) ??
        RouteColourScheme(iconColour: scheme.secondaryContainer, textColour: scheme.onSecondaryContainer);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: colours.iconColour, borderRadius: BorderRadius.circular(12)),
      // A column centres the name vertically in the strip's fixed height.
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Text(route.nameFor(AppStrings.languageCode), style: TextStyle(color: colours.textColour, fontSize: 11, fontWeight: FontWeight.bold,),)
      ],),
    );
  }
}
