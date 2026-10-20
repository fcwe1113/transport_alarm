/// An operator's stop, as fetched from its API (HK operators), before it's
/// matched to a GTFS stop.
class TransportStop {
  /// "providerCode:rawId", such as "kmb:" plus KMB's stop ID.
  final String id;
  /// Keyed by language code.
  final Map<String, String> names;
  final double? lat;
  final double? lng;
  final String providerCode;

  const TransportStop({
    required this.id,
    required this.names,
    this.lat,
    this.lng,
    required this.providerCode,
  });
}
