// abstract class for transit provider
// todo make a provider template once the structure is set in stone

import 'dart:ui';

import 'package:transport_alarm/transit/models/live_eta.dart';
import 'package:transport_alarm/transit/models/route_colour_scheme.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/refresh_result.dart';

import 'models/transport_route.dart';
import 'transport_mode.dart';

abstract class TransitProvider {
  String get providerCode;
  String get providerName;
  String get transportMode => TransportMode.bus;
  // String get IconAsset; // contains the link to the icon
  Color get defaultIconColor;
  Color get defaultTextColor;

  // Future<List<BusStop>> fetchStops({bool forceRefresh});
  // Future<List<BusRoute>> fetchRoutes({bool forceRefresh});
  Future<RefreshResult> refresh({bool forceRefresh = false, ProgressCallback? onProgress});
  Future<bool> isStale();
  RouteColourScheme coloursForRoute(TransportRoute route) => RouteColourScheme(iconColour: defaultIconColor, textColour: defaultTextColor);

  Future<List<LiveEta>> fetchLiveEta(String rawStopId);
  Future<List<LiveEta>> fetchLiveEtaForRoute(String rawStopId, String routeNumber);

  /// Returns a route-specific endpoint to persist on an alarm for push-time
  /// ETA requests. Providers can override this as their API shape requires.
  String? alarmEtaUrl({required String operatorStopId, required TransportRoute route}) => null;

}
