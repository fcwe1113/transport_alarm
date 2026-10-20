import 'dart:convert';

import 'package:transport_alarm/transit/models/transport_route.dart';
import 'package:transport_alarm/transit/models/live_eta.dart';
import 'package:transport_alarm/transit/models/route_colour_scheme.dart';
import 'package:transport_alarm/transit/refresh_result.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/staleness_tracker.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:flutter/material.dart';

import '../../../models/transport_stop.dart';
import '../../../progress_callback.dart';
import '../../../transit_provider.dart';

/// KMB (and Long Win), through data.etabus.gov.hk. KMB has endpoints for
/// every stop and every route, so a refresh fetches those two lists and
/// then each route's stop list.
class KmbProvider extends TransitProvider {
  final ApiCaller _apiCaller;
  static const _baseUrl = 'https://data.etabus.gov.hk/v1/transport/kmb';
  static const _stopsEndpointName = "stops";
  static const _stopsUrl = '$_baseUrl/stop';
  static const _routesEndpointName = "routes";
  static const _routesUrl = '$_baseUrl/route';

  GtfsDatabase get _db => GtfsDatabase.forLocale("hk");

  KmbProvider(this._apiCaller);

  @override
  String get providerCode => "kmb";

  @override
  String get providerName => "KMB";

  @override
  String cleanDestination(String destination) => destination;

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
    final db = _db;
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
      final serviceType = _serviceType(route);
      items.add(
        BatchCallItem<TransportRoute, List<String>>(
          key: route,
          endpointName: "route_stop_${route.routeNumber}_${route.bound}_$serviceType",
          url: '$_baseUrl/route-stop/${route.routeNumber}/$direction/$serviceType',
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

    final failed = batchResult.failedKeys.map((r) => r.routeNumber).toList();
    // Only a complete refresh resets the age; a partial one is retried.
    if (failed.isEmpty) {
      await StalenessTracker().markRefreshed('hk', providerCode);
    }
    return RefreshResult(failedItems: failed);
  }

  /// Every route's arrivals at a KMB stop.
  @override
  Future<List<LiveEta>> fetchLiveEta(String rawStopId) =>
      _fetchEtas(Uri.parse('$_baseUrl/stop-eta/$rawStopId'));

  /// One route's arrivals at a KMB stop. [serviceType] picks the variant;
  /// "1" is the normal service.
  @override
  Future<List<LiveEta>> fetchLiveEtaForRoute(
    String rawStopId,
    String routeNumber, {
    String serviceType = "1",
  }) =>
      _fetchEtas(Uri.parse('$_baseUrl/eta/$rawStopId/$routeNumber/$serviceType'));

  /// Reads a KMB ETA response. An entry with missing fields or no "eta" (no
  /// prediction) is read as far as it goes, rather than failing the rest.
  Future<List<LiveEta>> _fetchEtas(Uri url) async {
    final response = await ApiCaller.get(url);
    if (response.statusCode != 200) {
      throw Exception("Live ETA fetch failed: ${response.statusCode}");
    }
    final decoded = jsonDecode(response.body);
    final data = decoded is Map<String, dynamic> && decoded["data"] is List
        ? decoded["data"] as List
        : throw const FormatException("KMB ETA response has no data list.");

    String text(Object? value) => value?.toString() ?? "";
    return data.whereType<Map<String, dynamic>>().map((entry) {
      final etaString = entry["eta"]?.toString();
      return LiveEta(
        routeNumber: text(entry["route"]),
        bound: text(entry["dir"]),
        destination: {"en": text(entry["dest_en"]), "zh-Hant": text(entry["dest_tc"]), "zh-Hans": text(entry["dest_sc"])},
        etaTime: etaString == null || etaString.isEmpty ? null : DateTime.tryParse(etaString)?.toUtc(),
        remark: entry["rmk_en"]?.toString(),
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
    return Uri.https(
      "data.etabus.gov.hk",
      "/v1/transport/kmb/eta/$rawStopId/${route.routeNumber}/${_serviceType(route)}",
    ).toString();
  }

  /// The route's service type, the last part of its ID; "1" if it has none.
  static String _serviceType(TransportRoute route) {
    final routeIdParts = route.id.split("_");
    final serviceType = routeIdParts.length > 1 ? routeIdParts.last : "";
    return serviceType.isEmpty ? "1" : serviceType;
  }

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

  /// Each route direction and service type, with an ID of
  /// "kmb:route_bound_serviceType".
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
          "en": r["orig_en"] as String? ?? "",
          "zh-Hant": r["orig_tc"] as String? ?? "",
          "zh-Hans": r["orig_sc"] as String? ?? "",
        },
        destinationText: {
          "en": r["dest_en"] as String? ?? "",
          "zh-Hant": r["dest_tc"] as String? ?? "",
          "zh-Hans": r["dest_sc"] as String? ?? "",
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
    if (await StalenessTracker().isStale('hk', providerCode)) return true;

    // Also stale if a refresh left data missing, whatever its age.
    final db = _db;
    if (!await db.hasOperatorStops(providerCode) ||
        !await db.hasOperatorRouteStops(providerCode)) {
      return true;
    }

    final routes = await db.getOperatorRoutes(providerCode);
    if (routes.isEmpty) return true;
    for (final route in routes) {
      if (!await db.hasRouteStops(route.id)) return true;
    }
    return false;
  }
}
