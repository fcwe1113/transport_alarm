import 'dart:convert';

import 'package:transport_alarm/transit/models/transport_route.dart';
import 'package:transport_alarm/transit/models/transport_stop.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/services/staleness_tracker.dart';
import 'package:transport_alarm/l10n/app_strings.dart';
import 'package:transport_alarm/transit/transit_provider.dart';
import 'package:flutter/material.dart';

import '../../../models/live_eta.dart';
import '../../../models/route_colour_scheme.dart';
import '../../../progress_callback.dart';
import '../../../refresh_result.dart';

// todo fix double routes present in both providers
// todo fix stop names

/// Citybus, through DATA.GOV.HK. It has no all-stops endpoint, so a refresh
/// collects stop IDs from each route's stop list and fetches each stop's
/// details.
class CtbProvider extends TransitProvider {
  final ApiCaller _apiCaller;
  static const _baseUrl = 'https://rt.data.gov.hk/v1/transport/citybus-nwfb';
  static const _routesEndpointName = "route";
  static const _routesUrl = '$_baseUrl/route/CTB';

  GtfsDatabase get _db => GtfsDatabase.forLocale("hk");

  CtbProvider(this._apiCaller);

  @override
  String get providerCode => "ctb";
  @override
  String get providerName => "Citybus";

  @override
  String cleanDestination(String destination) => destination;

  @override
  Color get defaultIconColor => const Color(0xFFFFD200);
  @override
  Color get defaultTextColor => const Color(0xFF002FFF);

  @override
  RouteColourScheme coloursForRoute(TransportRoute route) {
    bool isAirportRoute(TransportRoute route) {
      return route.routeNumber.startsWith("A") ||
          route.routeNumber.startsWith("NA");
    }

    bool isNightRoute(TransportRoute route) {
      return route.routeNumber.startsWith("N");
    }

    if (isAirportRoute(route)) {
      return const RouteColourScheme(
        iconColour: Color(0xFF822905),
        textColour: Color(0xFFD6B706),
      );
    }

    if (isNightRoute(route)) {
      return const RouteColourScheme(
        iconColour: Color(0xFF090740),
        textColour: Color(0xFFFFD200),
      );
    }

    return super.coloursForRoute(route);
  }

  Future<List<TransportRoute>> _fetchRoutes({bool forceRefresh = false}) async {
    final cachedRoutes = await _db.getOperatorRoutes(providerCode);
    final routes = await _apiCaller.call(
      providerCode: providerCode,
      endpointName: _routesEndpointName,
      url: _routesUrl,
      parseRaw: _parseRoutesRaw,
      forceRefresh: forceRefresh || cachedRoutes.isEmpty,
    );
    return routes ?? cachedRoutes;
  }

  @override
  Future<RefreshResult> refresh({
    bool forceRefresh = false,
    ProgressCallback? onProgress,
  }) async {
    final db = _db;
    onProgress?.call(
      AppStrings.text('transit.provider_fetch_routes', {
        'providerName': providerName,
      }),
      null,
    );
    final previousRouteIds = (await db.getOperatorRoutes(providerCode)).map((r) => r.id).toSet();
    final routes = await _fetchRoutes(forceRefresh: forceRefresh);
    await db.upsertOperatorRoutes(routes);
    // Routes Citybus no longer lists, or saved under an older ID format.
    await db.deleteOperatorRoutes(previousRouteIds.difference(routes.map((r) => r.id).toSet()));

    // No all-stops endpoint: compile the stop list from each route's stops.
    final routeStopItems = <BatchCallItem<TransportRoute, List<String>>>[];
    for (final route in routes) {
      final direction = route.bound == "O" ? "outbound" : "inbound";
      routeStopItems.add(
        BatchCallItem<TransportRoute, List<String>>(
          key: route,
          endpointName: "route_stop_${route.routeNumber}_${route.bound}",
          url: '$_baseUrl/route-stop/CTB/${route.routeNumber}/$direction',
          parseRaw: _parseRouteStopIdsRaw,
          forceRefresh: !await db.hasRouteStops(route.id),
        ),
      );
    }

    final routeStopResult = await _apiCaller
        .callBatch<TransportRoute, List<String>>(
          providerCode: providerCode,
          items: routeStopItems,
          forceRefresh: forceRefresh,
          onProgress: (done, total) => onProgress?.call(
            AppStrings.text('transit.provider_fetch_route_stops', {
              'providerName': providerName,
              'done': done,
              'total': total,
            }),
            total > 0 ? done / total : null,
          ),
        );

    // The route list doesn't say which directions a route runs, so both are
    // listed; a direction with no stops (such as a circular route's inbound)
    // doesn't run, and is dropped so it isn't refetched as missing data.
    final unusedDirections = <String>[];
    for (final entry in routeStopResult.results.entries) {
      final route = entry.key;
      final rawStopIds = entry.value;
      if (rawStopIds.isEmpty) {
        unusedDirections.add(route.id);
        continue;
      }
      final operatorStopIds = rawStopIds
          .map((id) => "$providerCode:$id")
          .toList();
      await db.upsertRouteStops(route.id, operatorStopIds);
    }
    await db.deleteOperatorRoutes(unusedDirections);

    final uniqueRawStopIds = <String>{};
    for (final operatorStopId in await db.getOperatorStopIdsForProvider(
      providerCode,
    )) {
      final separator = operatorStopId.indexOf(':');
      uniqueRawStopIds.add(
        separator < 0
            ? operatorStopId
            : operatorStopId.substring(separator + 1),
      );
    }
    for (final rawStopIds in routeStopResult.results.values) {
      uniqueRawStopIds.addAll(rawStopIds);
    }

    final stopDetailItems = <BatchCallItem<String, TransportStop>>[];
    for (final rawStopId in uniqueRawStopIds) {
      stopDetailItems.add(
        BatchCallItem<String, TransportStop>(
          key: rawStopId,
          endpointName: "stop_$rawStopId",
          url: '$_baseUrl/stop/$rawStopId',
          parseRaw: ((rawJson) => _parseStopDetailRaw(rawJson, rawStopId)),
          forceRefresh: !await db.hasOperatorStop('$providerCode:$rawStopId'),
        ),
      );
    }

    final stopDetailResult = await _apiCaller.callBatch<String, TransportStop>(
      providerCode: providerCode,
      items: stopDetailItems,
      forceRefresh: forceRefresh,
      onProgress: (done, total) => onProgress?.call(
        AppStrings.text('transit.provider_fetch_stop_details', {
          'providerName': providerName,
          'done': done,
          'total': total,
        }),
        total > 0 ? done / total : null,
      ),
    );

    await db.upsertOperatorStops(stopDetailResult.results.values.toList());

    onProgress?.call(
      AppStrings.text('transit.provider_setup_complete', {
        'providerName': providerName,
      }),
      1.0,
    );

    final failed = <String>[
      ...routeStopResult.failedKeys.map((r) => "route-stop ${r.routeNumber}"),
      ...stopDetailResult.failedKeys.map((id) => "stop $id"),
    ];
    // Only a complete refresh resets the age; a partial one is retried.
    if (failed.isEmpty) {
      await StalenessTracker().markRefreshed('hk', providerCode);
    }
    return RefreshResult(failedItems: failed);
  }

  @override
  Future<bool> isStale() async {
    if (await StalenessTracker().isStale('hk', providerCode)) return true;

    // Also stale if a refresh left data missing, whatever its age.
    final db = _db;
    final routes = await db.getOperatorRoutes(providerCode);
    if (routes.isEmpty ||
        !await db.hasOperatorStops(providerCode) ||
        !await db.hasOperatorRouteStops(providerCode)) {
      return true;
    }
    for (final route in routes) {
      if (!await db.hasRouteStops(route.id)) return true;
    }
    return false;
  }

  @override
  Future<List<LiveEta>> fetchLiveEta(String rawStopId) async {
    final operatorStopId = "$providerCode:$rawStopId";
    final routeNumbers = await _db.getRouteNumbersForOperatorStop(operatorStopId);
    final allEtas = <LiveEta>[];
    for (final routeNumber in routeNumbers) {
      try {
        allEtas.addAll(await fetchLiveEtaForRoute(rawStopId, routeNumber));
      } catch (_) {
        // One route failing still leaves the others' arrivals.
      }
    }

    return allEtas;
  }

  @override
  Future<List<LiveEta>> fetchLiveEtaForRoute(
    String rawStopId,
    String routeNumber,
  ) async {
    final response = await ApiCaller.get(Uri.parse('$_baseUrl/eta/CTB/$rawStopId/$routeNumber'));
    if (response.statusCode != 200) {
      throw Exception("Live ETA fetch failed: ${response.statusCode}");
    }

    final decoded = jsonDecode(response.body);
    final data = decoded["data"] as List;

    return data.map((entry) {
      final etaString = entry["eta"] as String?;
      return LiveEta(
        routeNumber: entry["route"] as String,
        bound: (entry["dir"] as String?) ?? "",
        destination: {"en": entry["dest_en"] as String, "zh-Hant": entry["dest_tc"] as String, "zh-Hans": entry["dest_sc"] as String},
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
    return Uri.https(
      "rt.data.gov.hk",
      "/v1/transport/citybus-nwfb/eta/CTB/$rawStopId/${route.routeNumber}",
    ).toString();
  }

  /// Each listed route in both directions: outbound as listed, and inbound
  /// with its origin and destination swapped. Directions that don't run are
  /// dropped in [refresh] once their stop lists come back empty.
  List<TransportRoute> _parseRoutesRaw(String rawJson) {
    final decoded = jsonDecode(rawJson);
    final List<dynamic> data = decoded["data"];
    return data.expand((r) {
      final routeNumber = r["route"] as String? ?? "";
      final origin = {
        "en": r["orig_en"] as String? ?? "",
        "zh-Hant": r["orig_tc"] as String? ?? "",
        "zh-Hans": r["orig_sc"] as String? ?? "",
      };
      final destination = {
        "en": r["dest_en"] as String? ?? "",
        "zh-Hant": r["dest_tc"] as String? ?? "",
        "zh-Hans": r["dest_sc"] as String? ?? "",
      };
      TransportRoute direction(String bound, Map<String, String> from, Map<String, String> to) => TransportRoute(
        id: "$providerCode:${routeNumber}_$bound",
        names: {"en": routeNumber, "zh-Hant": routeNumber},
        routeNumber: routeNumber,
        bound: bound,
        originText: from,
        destinationText: to,
        providerCode: providerCode,
        locale: "hk",
      );
      return [direction("O", origin, destination), direction("I", destination, origin)];
    }).toList();
  }

  List<String> _parseRouteStopIdsRaw(String rawJson) {
    final decoded = jsonDecode(rawJson);
    final data = decoded["data"] as List;
    return data.map((s) => s["stop"] as String).toList();
  }

  TransportStop _parseStopDetailRaw(String rawJson, String rawStopId) {
    final decoded = jsonDecode(rawJson);
    final s = decoded["data"];
    return TransportStop(
      id: "$providerCode:$rawStopId",
      names: {
        "en": s["name_en"] as String? ?? "",
        "zh-Hant": s["name_tc"] as String? ?? "",
        "zh-Hans": s["name_sc"] as String? ?? "",
      },
      lat: double.tryParse(s["lat"].toString()),
      lng: double.tryParse(s["long"].toString()),
      providerCode: providerCode,
    );
  }
}
