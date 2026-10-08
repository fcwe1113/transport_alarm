import 'dart:ui';

import 'package:transport_alarm/transit/models/live_eta.dart';
import 'package:transport_alarm/transit/models/route_colour_scheme.dart';
import 'package:transport_alarm/transit/models/transport_route.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/refresh_result.dart';
import 'package:transport_alarm/transit/transit_provider.dart';

class GbBodsProvider implements TransitProvider {
  @override
  String? alarmEtaUrl({required String operatorStopId, required TransportRoute route}) {
    // TODO: implement alarmEtaUrl
    throw UnimplementedError();
  }

  @override
  RouteColourScheme coloursForRoute(TransportRoute route) {
    // TODO: implement coloursForRoute
    throw UnimplementedError();
  }

  @override
  // TODO: implement defaultIconColor
  Color get defaultIconColor => throw UnimplementedError();

  @override
  // TODO: implement defaultTextColor
  Color get defaultTextColor => throw UnimplementedError();

  @override
  Future<List<LiveEta>> fetchLiveEta(String rawStopId) {
    // TODO: implement fetchLiveEta
    throw UnimplementedError();
  }

  @override
  Future<List<LiveEta>> fetchLiveEtaForRoute(String rawStopId, String routeNumber) {
    // TODO: implement fetchLiveEtaForRoute
    throw UnimplementedError();
  }

  @override
  Future<bool> isStale() {
    // TODO: implement isStale
    throw UnimplementedError();
  }

  @override
  // TODO: implement providerCode
  String get providerCode => throw UnimplementedError();

  @override
  // TODO: implement providerName
  String get providerName => throw UnimplementedError();

  @override
  Future<RefreshResult> refresh({bool forceRefresh = false, ProgressCallback? onProgress}) {
    // TODO: implement refresh
    throw UnimplementedError();
  }

  @override
  // TODO: implement transportMode
  String get transportMode => throw UnimplementedError();

}