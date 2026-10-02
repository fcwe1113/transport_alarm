// bus route data struct definition file

import 'package:transport_alarm/transit/models/transport_stop.dart';

class TransportRoute {
  final String id;
  final Map<String, String> names; // may hv locale diffs, maybe remove if not needed
  final String routeNumber;
  final String bound; // change if not adapting to new apis
  final Map<String, String> originText;
  final Map<String, String> destinationText; // the destination showed normally
  final List<TransportStop> stops;
  final String providerCode;

  const TransportRoute({
    required this.id,
    required this.names,
    required this.routeNumber,
    required this.bound,
    required this.originText,
    required this.destinationText,
    required this.providerCode,
    this.stops = const [],
  });

  TransportStop get origin => stops.isNotEmpty ? stops.first : TransportStop.placeholder(id: "$providerCode:origin_$routeNumber$bound", name: originText["en"] ?? "", providerCode: providerCode);
  TransportStop get destination => stops.isNotEmpty ? stops.last : TransportStop.placeholder(id: "$providerCode:destination_$routeNumber$bound", name: destinationText["en"] ?? "", providerCode: providerCode);

  TransportRoute copyWith({List<TransportStop>? stops}) {
    return TransportRoute(id: id, names: names, routeNumber: routeNumber, bound: bound, originText: originText, destinationText: destinationText, providerCode: providerCode, stops: stops ?? this.stops);
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

  static TransportRoute fromJson(Map<String, dynamic> json) => TransportRoute(
      id: json["id"],
      names: Map<String, String>.from(json["names"]),
      routeNumber: json["routeNumber"],
      bound: json["bound"],
      originText: Map<String, String>.from(json["originText"]),
      destinationText: Map<String, String>.from(json["destinationText"]),
      providerCode: json["providerCode"],
  );

  static List<TransportRoute> dedupeByRouteNumber(List<TransportRoute> routes) {
    final byRouteNumber = <String, TransportRoute>{};
    for (final route in routes) {
      byRouteNumber.putIfAbsent(route.routeNumber, () => route);
    }
    return byRouteNumber.values.toList();
  }

  static List<TransportRoute> dedupeByRouteAndDestination(List<TransportRoute> routes) {
    final uniqueRoutes = <String, TransportRoute>{};
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
