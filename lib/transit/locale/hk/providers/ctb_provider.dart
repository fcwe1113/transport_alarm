import 'dart:convert';
import 'dart:ui';

import 'package:transport_alarm/transit/models/transport_route.dart';
import 'package:transport_alarm/transit/models/transport_stop.dart';
import 'package:transport_alarm/transit/services/api_caller.dart';
import 'package:transport_alarm/transit/services/gtfs_database.dart';
import 'package:transport_alarm/transit/transit_provider.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../models/live_eta.dart';
import '../../../models/route_colour_scheme.dart';
import '../../../progress_callback.dart';
import '../../../refresh_result.dart';

// todo fix double routes present in both providers
// todo fix stop names
// query for all reused routenum
// SELECT t.route_number
// from operator_routes t
// GROUP by route_number
// HAVING COUNT(*) > 1

class CtbProvider extends TransitProvider{
  final ApiCaller _apiCaller;
  static const _routesEndpointName = "route";
  static const _routesUrl = 'https://rt.data.gov.hk/v1/transport/citybus-nwfb/route/CTB';

  CtbProvider(this._apiCaller);

  @override
  String get providerCode => "ctb";
  @override
  String get providerName => "Citybus";
  @override
  Color get defaultIconColor => const Color(0xFFFFD200);
  @override
  Color get defaultTextColor => const Color(0xFF002FFF);

  @override
  RouteColourScheme coloursForRoute(TransportRoute route) {

    bool isAirportRoute(TransportRoute route) {
      return route.routeNumber.startsWith("A") || route.routeNumber.startsWith("NA");
    }

    bool isNightRoute(TransportRoute route) {
      return route.routeNumber.startsWith("N");
    }

    if (isAirportRoute(route)) {
      return const RouteColourScheme(iconColour: Color(0xFF822905), textColour: Color(0xFFD6B706));
    }

    if (isNightRoute(route)) {
      return const RouteColourScheme(iconColour: Color(0xFF090740), textColour: Color(0xFFFFD200));
    }

    return super.coloursForRoute(route);
  }
  
  Future<List<TransportRoute>> _fetchRoutes({bool forceRefresh = false}) async {
    final routes = await _apiCaller.call(
        providerCode: providerCode, 
        endpointName: _routesEndpointName, 
        url: _routesUrl, 
        parseRaw: _parseRoutesRaw, 
        forceRefresh: forceRefresh
    );
    return routes ?? await GtfsDatabase.forLocale("hk").getOperatorRoutes(providerCode);
  }
  
  @override
  Future<RefreshResult> refresh({bool forceRefresh = false, ProgressCallback? onProgress}) async {
    final db = GtfsDatabase.forLocale("hk");
    onProgress?.call("Fetching Citybus routes...", null);
    final routes = await _fetchRoutes(forceRefresh: forceRefresh);
    await db.upsertOperatorRoutes(routes);
    
    // ctb has no central all stops api so we need to compile
    // the stops list from the route-stop api
    final routeStopItems = routes.map((route) {
      final direction = route.bound == "O" ? "outbound" : "inbound";
      return BatchCallItem<TransportRoute, List<String>>(
          key: route,
          endpointName: "route_stop_${route.routeNumber}_${route.bound}",
          url: 'https://rt.data.gov.hk/v1/transport/citybus-nwfb/route-stop/CTB/${route.routeNumber}/$direction',
          parseRaw: _parseRouteStopIdsRaw
      );
    }).toList();

    final routeStopResult = await _apiCaller.callBatch<TransportRoute, List<String>>(
        providerCode: providerCode,
        items: routeStopItems,
        forceRefresh: forceRefresh,
        onProgress: (done, total) => onProgress?.call("Fetching Citybus route-stop sequences ($done/$total)...", total > 0 ? done / total : null)
    );

    for (final entry in routeStopResult.results.entries) {
      final route = entry.key;
      final rawStopIds = entry.value;
      final operatorStopIds = rawStopIds.map((id) => "$providerCode:$id").toList();
      await db.upsertRouteStops(route.id, operatorStopIds);
    }

    final uniqueRawStopIds = <String>{};
    for (final rawStopIds in routeStopResult.results.values) {
      uniqueRawStopIds.addAll(rawStopIds);
    }

    final stopDetailItems = uniqueRawStopIds.map((rawStopId) {
      return BatchCallItem<String, TransportStop>(
          key: rawStopId,
          endpointName: "stop_$rawStopId",
          url: 'https://rt.data.gov.hk/v1/transport/citybus-nwfb/stop/$rawStopId',
          parseRaw: ((rawJson) => _parseStopDetailRaw(rawJson, rawStopId))
      );
    }).toList();

    final stopDetailResult = await _apiCaller.callBatch<String, TransportStop>(
        providerCode: providerCode,
        items: stopDetailItems,
        forceRefresh: forceRefresh,
        onProgress: (done, total) => onProgress?.call("Fetching Citybus stop details ($done/$total)", total > 0 ? done / total : null)
    );

    await db.upsertOperatorStops(stopDetailResult.results.values.toList());

    onProgress?.call("Citybus setup complete", 1.0);

    final failed = <String>[
      ...routeStopResult.failedKeys.map((r) => "route-stop ${r.routeNumber}"),
      ...stopDetailResult.failedKeys.map((id) => "stop $id")
    ];
    return RefreshResult(failedItems: failed);
  }

  @override
  Future<bool> isStale() {
    return _apiCaller.isEndpointStale(providerCode, _routesEndpointName, maxAge: const Duration(days: 7));
  }

  @override
  Future<List<LiveEta>> fetchLiveEta(String rawStopId) async {
    final operatorStopId = "$providerCode:$rawStopId";
    final routeNumbers = await GtfsDatabase.forLocale("hk").getRouteNumbersForOperatorStop(operatorStopId);
    final allEtas = <LiveEta>[];
    for (final routeNumber in routeNumbers) {
      try {
        allEtas.addAll(await fetchLiveEtaForRoute(rawStopId, routeNumber));
      } catch (_) {
        // do nothing
      }
    }

    return allEtas;
  }

  @override
  Future<List<LiveEta>> fetchLiveEtaForRoute(String rawStopId, String routeNumber) async {
    final url = 'https://rt.data.gov.hk/v1/transport/citybus-nwfb/eta/CTB/$rawStopId/$routeNumber';
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) throw Exception("Live ETA fetch failed: ${response.statusCode}");

    final decoded = jsonDecode(response.body);
    final data = decoded["data"] as List;

    return data.map((entry) {
      final etaString = entry["eta"] as String?;
      return LiveEta(
          routeNumber: entry["route"] as String,
          bound: (entry["dir"] as String?) ?? "",
          etaTime: etaString != null ? DateTime.parse(etaString).toUtc() : null,
          remark: entry["rmk_en"] as String?
      );
    }).toList();
  }

  @override
  String? alarmEtaUrl({required String operatorStopId, required TransportRoute route}) {
    final separator = operatorStopId.indexOf(":");
    if (separator < 0 || separator == operatorStopId.length - 1) return null;
    final rawStopId = operatorStopId.substring(separator + 1);
    return Uri.https(
      "rt.data.gov.hk",
      "/v1/transport/citybus-nwfb/eta/CTB/$rawStopId/${route.routeNumber}",
    ).toString();
  }

  List<TransportRoute> _parseRoutesRaw(String rawJson) {
    final decoded = jsonDecode(rawJson);
    final List<dynamic> data = decoded["data"];
    return data.map((r) {
      final routeNumber = r["route"] as String? ?? "";
      return TransportRoute(
          id: "$providerCode:$routeNumber", 
          names: {"en": routeNumber, "zh-Hant": routeNumber}, 
          routeNumber: routeNumber, 
          bound: "O", 
          originText: {"en": r["orig_en"] as String? ?? "", "zh-Hant": r["orig_tc"] as String? ?? "", "zh-Hans": r["orig_sc"] as String? ?? ""},
          destinationText: {"en": r["dest_en"] as String? ?? "", "zh-Hant": r["dest_tc"] as String? ?? "", "zh-Hans": r["dest_sc"] as String? ?? ""},
          providerCode: providerCode
      );
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
        names: {"en": s["name_en"] as String? ?? "", "zh-Hant": s["name_tc"] as String? ?? "", "zh-Hans": s["name_sc"] as String? ?? ""},
        lat: double.tryParse(s["lat"].toString()),
        lng: double.tryParse(s["long"].toString()),
        providerCode: providerCode
    );
  }

}
