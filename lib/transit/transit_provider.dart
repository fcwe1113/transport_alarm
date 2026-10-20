import 'dart:ui';

import 'package:transport_alarm/transit/models/live_eta.dart';
import 'package:transport_alarm/transit/models/route_colour_scheme.dart';
import 'package:transport_alarm/transit/progress_callback.dart';
import 'package:transport_alarm/transit/refresh_result.dart';

import 'models/transport_route.dart';
import 'transport_mode.dart';

/// One transport operator's data and live arrivals, such as KMB or BODS.
/// Each locale lists its providers; adding an operator means implementing
/// this.
abstract class TransitProvider {
  /// Short code stored with routes and operator stop IDs ("provider:id").
  String get providerCode;
  /// Shown to the user, such as in data refresh failures.
  String get providerName;
  String get transportMode => TransportMode.bus;
  Color get defaultIconColor;
  Color get defaultTextColor;

  /// Downloads the provider's routes and stops into the locale database.
  Future<RefreshResult> refresh({bool forceRefresh = false, ProgressCallback? onProgress});

  /// Whether [refresh] is due.
  Future<bool> isStale();

  /// A route pill's colours; the provider's defaults unless overridden.
  RouteColourScheme coloursForRoute(TransportRoute route) => RouteColourScheme(iconColour: defaultIconColor, textColour: defaultTextColor);

  /// Cleans a destination name from this provider's data for display.
  /// Providers whose names need no cleanup return [destination] unchanged.
  String cleanDestination(String destination);

  /// Live arrivals at an operator stop, for every route.
  Future<List<LiveEta>> fetchLiveEta(String rawStopId);

  /// Live arrivals at an operator stop for one route.
  Future<List<LiveEta>> fetchLiveEtaForRoute(String rawStopId, String routeNumber);

  /// Returns a route-specific endpoint to persist on an alarm for push-time
  /// ETA requests, or null when the provider has none. Providers can
  /// override this as their API shape requires.
  String? alarmEtaUrl({required String operatorStopId, required TransportRoute route}) => null;
}
