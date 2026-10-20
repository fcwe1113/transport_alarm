import 'package:transport_alarm/transit/models/transport_route.dart';

/// A route's next arrival at a stop, live or from the timetable, as shown
/// on the alarm card and the stop sheet.
class RouteArrival {
  final TransportRoute route;
  /// This trip's destination by language code; may be empty, in which case
  /// the route's own destination is shown.
  final Map<String, String> destination;
  final int minutesFromNow;
  /// From a live prediction rather than the timetable.
  final bool isLive;

  const RouteArrival({required this.route, required this.destination, required this.minutesFromNow, required this.isLive});
}
