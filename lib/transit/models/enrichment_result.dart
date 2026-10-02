import 'package:transport_alarm/transit/models/transport_stop.dart';

class EnrichmentResult {
  final List<TransportStop> stops;
  final List<String> failedRouteNumbers;

  const EnrichmentResult({required this.stops, required this.failedRouteNumbers});
}