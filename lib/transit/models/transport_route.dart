/// One direction of a route from a provider, as stored in the locale
/// database. Text fields are keyed by language code.
class TransportRoute {
  /// The provider's own route ID, unique within its locale.
  final String id;
  /// The route's display name, such as "N260", where it differs by language.
  final Map<String, String> names;
  final String routeNumber;
  /// The provider's direction code, such as KMB's "I" or "O".
  final String bound;
  final Map<String, String> originText;
  /// The destination shown on the route.
  final Map<String, String> destinationText;
  final String providerCode;
  final String locale;
  /// GB only: the operating agency's name and operator code (NOC), for
  /// matching live vehicles.
  final String? agency;
  final String? agencyNoc;

  const TransportRoute({
    required this.id,
    required this.names,
    required this.routeNumber,
    required this.bound,
    required this.originText,
    required this.destinationText,
    required this.providerCode,
    required this.locale,
    this.agency,
    this.agencyNoc,
  });

  /// The route's name in [languageCode], then English, then its number.
  String nameFor(String languageCode) =>
      _localizedValue(names, languageCode) ?? routeNumber;

  /// The destination in [languageCode], then English, or empty.
  String destinationNameFor(String languageCode) =>
      _localizedValue(destinationText, languageCode) ?? '';

  static String? _localizedValue(
    Map<String, String> values,
    String languageCode,
  ) {
    final localized = values[languageCode]?.trim();
    if (localized != null && localized.isNotEmpty) return localized;
    final english = values['en']?.trim();
    if (english != null && english.isNotEmpty) return english;
    return null;
  }

  /// The first route of each route number, for showing each number once.
  static List<TransportRoute> dedupeByRouteNumber(List<TransportRoute> routes) {
    final byRouteNumber = <String, TransportRoute>{};
    for (final route in routes) {
      byRouteNumber.putIfAbsent(route.routeNumber, () => route);
    }
    return byRouteNumber.values.toList();
  }

  /// The first route of each route number and destination in [languageCode],
  /// so each direction is listed once.
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
