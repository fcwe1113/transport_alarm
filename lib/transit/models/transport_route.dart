// bus route data struct definition file

import 'package:transport_alarm/transit/models/transport_stop.dart';
import 'package:transport_alarm/l10n/app_strings.dart';

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

  TransportStop get origin => stops.isNotEmpty ? stops.first : TransportStop.placeholder(id: "$providerCode:origin_$routeNumber$bound", name: originNameFor(AppStrings.languageCode), providerCode: providerCode);
  TransportStop get destination => stops.isNotEmpty ? stops.last : TransportStop.placeholder(id: "$providerCode:destination_$routeNumber$bound", name: destinationNameFor(AppStrings.languageCode), providerCode: providerCode);

  String nameFor(String languageCode) => _localizedValue(names, languageCode) ?? routeNumber;
  String originNameFor(String languageCode) => _localizedValue(originText, languageCode) ?? '';
  String destinationNameFor(String languageCode) => _localizedValue(destinationText, languageCode) ?? '';

  static String? _localizedValue(Map<String, String> values, String languageCode) {
    final localized = values[languageCode]?.trim();
    if (localized != null && localized.isNotEmpty) return localized;
    final english = values['en']?.trim();
    if (english != null && english.isNotEmpty) return english;
    return null;
  }

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

  static List<TransportRoute> dedupeByRouteAndDestination(
    List<TransportRoute> routes, {
    String languageCode = 'en',
  }) {
    final uniqueRoutes = <String, TransportRoute>{};
    for (final route in routes) {
      final destination = route.destinationNameFor(languageCode);
      uniqueRoutes.putIfAbsent(
        '${route.routeNumber}\u0000$destination',
        () => route,
      );
    }
    return uniqueRoutes.values.toList();
  }
}
