import 'package:transport_alarm/transit/models/transport_route.dart';

class RouteArrival {
  final TransportRoute route;
  final Map<String, String> destination;
  final int minutesFromNow;
  final bool isLive;

  const RouteArrival({required this.route, required this.destination, required this.minutesFromNow, required this.isLive});
}
