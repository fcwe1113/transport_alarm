// bus route data struct definition file

import 'package:transport_alarm/transit/models/bus_stop.dart';

class BusRoute {
  final String id;
  final Map<String, String> names; // may hv locale diffs, maybe remove if not needed
  final String routeNumber;
  final String bound; // change if not adapting to new apis
  final Map<String, String> originText;
  final Map<String, String> destinationText; // the destination showed normally
  final List<BusStop> stops;
  final String providerCode;

  const BusRoute({
    required this.id,
    required this.names,
    required this.routeNumber,
    required this.bound,
    required this.originText,
    required this.destinationText,
    required this.providerCode,
    this.stops = const [],
  });

  BusStop get origin => stops.isNotEmpty ? stops.first : BusStop.placeholder(id: "$providerCode:origin_$routeNumber$bound", name: originText["en"] ?? "", providerCode: providerCode);
  BusStop get destination => stops.isNotEmpty ? stops.last : BusStop.placeholder(id: "$providerCode:destination_$routeNumber$bound", name: destinationText["en"] ?? "", providerCode: providerCode);

  BusRoute copyWith({List<BusStop>? stops}) {
    return BusRoute(id: id, names: names, routeNumber: routeNumber, bound: bound, originText: originText, destinationText: destinationText, providerCode: providerCode, stops: stops ?? this.stops);
  }

  Map<String, dynamic> toJson() => {
    "id": id,
    "names": names,
    "routeNumber": routeNumber,
    "bound": bound,
    "originText": originText,
    "destinationText": destinationText,
    "providerCode": providerCode,
  };

  static BusRoute fromJson(Map<String, dynamic> json) => BusRoute(
      id: json["id"],
      names: Map<String, String>.from(json["names"]),
      routeNumber: json["routeNumber"],
      bound: json["bound"],
      originText: Map<String, String>.from(json["originText"]),
      destinationText: Map<String, String>.from(json["destinationText"]),
      providerCode: json["providerCode"],
  );

  static List<BusRoute> dedupeByRouteNumber(List<BusRoute> routes) {
    final byRouteNumber = <String, BusRoute>{};
    for (final route in routes) {
      byRouteNumber.putIfAbsent(route.routeNumber, () => route);
    }
    return byRouteNumber.values.toList();
  }

  static List<BusRoute> dedupeByRouteAndDestination(List<BusRoute> routes) {
    final uniqueRoutes = <String, BusRoute>{};
    for (final route in routes) {
      final destination = route.destinationText['en'] ?? '';
      uniqueRoutes.putIfAbsent(
        '${route.routeNumber}\u0000$destination',
        () => route,
      );
    }
    return uniqueRoutes.values.toList();
  }
}
