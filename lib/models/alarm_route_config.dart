import '../transit/transport_mode.dart';

/// Route-specific data the notification handler needs without resolving the
/// operator stop from the GTFS database for every push.
class AlarmRouteConfig {
  final String routeNumber;
  final String mode;
  final String providerCode;
  final String apiUrl;

  const AlarmRouteConfig({
    required this.routeNumber,
    required this.mode,
    required this.providerCode,
    required this.apiUrl,
  });

  Map<String, dynamic> toJson() => {
        'routeNumber': routeNumber,
        'mode': mode,
        'providerCode': providerCode,
        'apiUrl': apiUrl,
      };

  factory AlarmRouteConfig.fromJson(Map<String, dynamic> json) =>
      AlarmRouteConfig(
        routeNumber: json['routeNumber'] as String,
        mode: json['mode'] as String? ?? TransportMode.bus,
        providerCode: json['providerCode'] as String,
        apiUrl: json['apiUrl'] as String,
      );
}
