import 'dart:convert';
import 'dart:core';

import 'package:transport_alarm/transit/models/transport_route.dart';
import 'package:transport_alarm/transit/models/live_eta.dart';
import 'package:transport_alarm/transit/models/route_colour_scheme.dart';
import 'package:transport_alarm/transit/refresh_result.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:flutter/material.dart';

import '../../../models/transport_stop.dart';
import '../../../progress_callback.dart';
import '../../../transit_provider.dart';

/// KMB's implementation of transit provider
/// includes all KMB related data and API handling
///
/// KMB offers a full stop list and full route list API endpoint so we will be using that
class KmbProvider extends TransitProvider {
  // implements means to follow the provided interface, not extending bc theres nothing to build upon
  final ApiCaller _apiCaller;
  static const _stopsEndpointName = "stops";
  static const _stopsUrl = 'https://data.etabus.gov.hk/v1/transport/kmb/stop';
  static const _routesEndpointName = "routes";
  static const _routesUrl = "https://data.etabus.gov.hk/v1/transport/kmb/route";

  KmbProvider(this._apiCaller);

  @override
  String get providerCode => "kmb";

  @override
  String get providerName => "KMB";

  @override
  Color get defaultIconColor => const Color(0xDAFF291C);

  @override
  Color get defaultTextColor => Colors.white;

  @override
  RouteColourScheme coloursForRoute(TransportRoute route) {
    bool isAirportRoute(TransportRoute route) {
      return route.routeNumber.startsWith("A") ||
          route.routeNumber.startsWith("E");
    }

    bool isNightRoute(TransportRoute route) {
      return route.routeNumber.startsWith("N");
    }

    if (isNightRoute(route)) {
      return const RouteColourScheme(
        iconColour: Color(0xFF090740),
        textColour: Colors.white,
      );
    }

    if (isAirportRoute(route)) {
      return const RouteColourScheme(
        iconColour: Colors.orange,
        textColour: Colors.white,
      );
    }

    return super.coloursForRoute(route);
  }

  @override
  Future<RefreshResult> refresh({
    bool forceRefresh = false,
    ProgressCallback? onProgress,
  }) async {
    final db = GtfsDatabase.forLocale("hk");
    final hasStops = await db.hasOperatorStops(providerCode);
    final cachedRoutes = await db.getOperatorRoutes(providerCode);
    onProgress?.call(
      AppStrings.text('transit.provider_fetch_stops', {
        'providerName': providerName,
      }),
      null,
    );
    final freshStops = await _apiCaller.call<List<TransportStop>>(
      providerCode: providerCode,
      endpointName: _stopsEndpointName,
      url: _stopsUrl,
      parseRaw: _parseStopsRaw,
      forceRefresh: forceRefresh || !hasStops,
    );
    if (freshStops != null) {
      await db.upsertOperatorStops(freshStops);
    }

    onProgress?.call(
      AppStrings.text('transit.provider_fetch_routes', {
        'providerName': providerName,
      }),
      null,
    );
    final freshRoutes = await _apiCaller.call<List<TransportRoute>>(
      providerCode: providerCode,
      endpointName: _routesEndpointName,
      url: _routesUrl,
      parseRaw: _parseRoutesRaw,
      forceRefresh: forceRefresh || cachedRoutes.isEmpty,
    );
    if (freshRoutes != null) {
      await db.upsertOperatorRoutes(freshRoutes);
    }

    final routesToLink = freshRoutes ?? cachedRoutes;
    final items = <BatchCallItem<TransportRoute, List<String>>>[];
    for (final route in routesToLink) {
      final direction = route.bound == "O" ? "outbound" : "inbound";
      items.add(
        BatchCallItem<TransportRoute, List<String>>(
          key: route,
          endpointName: "route_stop_${route.routeNumber}_${route.bound}_1",
          url:
              'https://data.etabus.gov.hk/v1/transport/kmb/route-stop/${route.routeNumber}/$direction/1',
          parseRaw: _parseRouteStopIdsRaw,
          forceRefresh: !await db.hasRouteStops(route.id),
        ),
      );
    }

    final batchResult = await _apiCaller
        .callBatch<TransportRoute, List<String>>(
          providerCode: providerCode,
          items: items,
          forceRefresh: forceRefresh,
          maxAge: const Duration(days: 7),
          onProgress: (done, total) => onProgress?.call(
            AppStrings.text('transit.provider_fetch_route_stops', {
              'providerName': providerName,
              'done': done,
              'total': total,
            }),
            total > 0 ? done / total : null,
          ),
        );

    for (final entry in batchResult.results.entries) {
      final route = entry.key;
      final rawStopIds = entry.value;
      final operatorStopIds = rawStopIds
          .map((id) => "$providerCode:$id")
          .toList();
      await db.upsertRouteStops(route.id, operatorStopIds);
    }

    onProgress?.call(
      AppStrings.text('transit.provider_setup_complete', {
        'providerName': providerName,
      }),
      1.0,
    );

    return RefreshResult(
      failedItems: batchResult.failedKeys.map((r) => r.routeNumber).toList(),
    );
  }

  @override
  Future<List<LiveEta>> fetchLiveEta(String rawStopId) async {
    final url =
        'https://data.etabus.gov.hk/v1/transport/kmb/stop-eta/$rawStopId';
    final response = await ApiCaller.get(Uri.parse(url));

    if (response.statusCode != 200) {
      throw Exception("Live ETA fetch failed: ${response.statusCode}");
    }

    final decoded = jsonDecode(response.body);
    final data = decoded["data"] as List;

    return data.map((entry) {
      final etaString = entry["eta"] as String?;
      return LiveEta(
        routeNumber: entry["route"] as String,
        bound: entry["dir"] as String,
        etaTime: etaString != null ? DateTime.parse(etaString).toUtc() : null,
        remark: entry["rmk_en"] as String?,
      );
    }).toList();
  }

  @override
  Future<List<LiveEta>> fetchLiveEtaForRoute(
    String rawStopId,
    String routeNumber, {
    String serviceType = "1",
  }) async {
    final url =
        "https://data.etabus.gov.hk/v1/transport/kmb/eta/${rawStopId}/${routeNumber}/${serviceType}";
    final response = await ApiCaller.get(Uri.parse(url));
    if (response.statusCode != 200)
      throw Exception("Live ETA fetch failed: ${response.statusCode}");

    final decoded = jsonDecode(response.body);
    final data = decoded["data"] as List;
    return data.map((entry) {
      final etaString = entry["eta"] as String?;
      return LiveEta(
        routeNumber: entry["route"] as String,
        bound: entry["dir"] as String? ?? "",
        etaTime: etaString != null ? DateTime.parse(etaString).toUtc() : null,
        remark: entry["rmk_en"] as String?,
      );
    }).toList();
  }

  @override
  String? alarmEtaUrl({
    required String operatorStopId,
    required TransportRoute route,
  }) {
    final separator = operatorStopId.indexOf(":");
    if (separator < 0 || separator == operatorStopId.length - 1) return null;
    final rawStopId = operatorStopId.substring(separator + 1);
    final routeIdParts = route.id.split("_");
    final serviceType = routeIdParts.length > 1 ? routeIdParts.last : "1";
    return Uri.https(
      "data.etabus.gov.hk",
      "/v1/transport/kmb/eta/$rawStopId/${route.routeNumber}/$serviceType",
    ).toString();
  }

  /// transforms stops data into forms the app requires
  /// in this case just slotting the different fields the api
  /// responded into the correct slot
  List<TransportStop> _parseStopsRaw(String rawJson) {
    final decoded = jsonDecode(rawJson);
    final List<dynamic> data = decoded["data"];

    return data
        .map(
          (s) => TransportStop(
            id: "$providerCode:${s["stop"]}",
            names: {
              "en": s["name_en"] as String? ?? "",
              "zh-Hant": s["name_tc"] as String? ?? "",
              "zh-Hans": s["name_sc"] as String? ?? "",
            },
            lat: double.tryParse(s["lat"].toString()),
            lng: double.tryParse(s["long"].toString()),
            providerCode: providerCode,
          ),
        )
        .toList();
  }

  /// transforms route data into forms the app requires
  /// in this case in addition to slotting data into the correct var
  /// placeholder bus stop objects were created to fill origin and destination
  List<TransportRoute> _parseRoutesRaw(String rawJson) {
    final decoded = jsonDecode(rawJson);
    final List<dynamic> data = decoded["data"];

    return data.map((r) {
      final routeNumber = r["route"] as String? ?? "";
      final bound = r["bound"] as String? ?? "";
      final serviceType = r["service_type"] as String? ?? "";
      return TransportRoute(
        id: "$providerCode:${routeNumber}_${bound}_$serviceType",
        names: {"en": routeNumber, "zh-Hant": routeNumber},
        routeNumber: routeNumber,
        bound: bound,
        originText: {
          "en": r["orig_en"],
          "zh-Hant": r["orig_tc"],
          "zh-Hans": r["orig_sc"],
        },
        destinationText: {
          "en": r["dest_en"],
          "zh-Hant": r["dest_tc"],
          "zh-Hans": r["dest_sc"],
        },
        providerCode: providerCode,
        locale: "hk",
      );
    }).toList();
  }

  List<String> _parseRouteStopIdsRaw(String rawJson) {
    final decoded = jsonDecode(rawJson);
    final data = decoded["data"] as List;
    return data.map((s) => s["stop"] as String).toList();
  }

  @override
  Future<bool> isStale() async {
    if (await _apiCaller.areAnyEndpointsStale(providerCode, [
      _stopsEndpointName,
      _routesEndpointName,
    ])) {
      return true;
    }

    final db = GtfsDatabase.forLocale('hk');
    if (!await db.hasOperatorStops(providerCode) ||
        !await db.hasOperatorRouteStops(providerCode)) {
      return true;
    }

    final routes = await db.getOperatorRoutes(providerCode);
    if (routes.isEmpty) return true;
    for (final route in routes) {
      if (!await db.hasRouteStops(route.id)) return true;
    }
    final routeStopEndpoints = routes.map(
      (route) => 'route_stop_${route.routeNumber}_${route.bound}_1',
    );
    return _apiCaller.areAnyEndpointsStale(providerCode, routeStopEndpoints);
  }
}
