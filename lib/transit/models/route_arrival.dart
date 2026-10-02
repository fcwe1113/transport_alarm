import 'package:transport_alarm/transit/models/transport_route.dart';

class RouteArrival {
  final TransportRoute route;
  final int minutesFromNow;
  final bool isLive;

  const RouteArrival({required this.route, required this.minutesFromNow, required this.isLive});
}