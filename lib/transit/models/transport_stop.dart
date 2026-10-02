/// transport stop data struct definition file
class TransportStop {
  final String id; // composited into providerCode:id
  final Map<String, String> names; // {"lang1": "name1", "lang2": "name2", ...}, defaults to "en"
  final double? lat;
  final double? lng;
  final String providerCode;
  final List<String> servingRouteIds;

  const TransportStop({
    required this.id,
    required this.names,
    this.lat,
    this.lng,
    required this.providerCode,
    this.servingRouteIds = const [] // defaults into empty list
  });

  String nameFor(String locale) => names[locale] ?? names["en"] ?? id;

  // special constructor for a placeholder stop object where only the name is known
  TransportStop.placeholder({
    required String id,
    required String name,
    required String providerCode,
  }) : this(
      id: id,
      names: {"en": name},
      providerCode: providerCode,
  );

  bool get isResolved => lat != null && lng != null;

  TransportStop copyWith({List<String>? servingRouteIds}) {
    return TransportStop(id: id, names: names, providerCode: providerCode, lat: lat, lng: lng, servingRouteIds: servingRouteIds ?? this.servingRouteIds);
  }

  Map<String, dynamic> toJson() => {
    "id": id,
    "names": names,
    "lat": lat,
    "lng": lng,
    "providerCode": providerCode,
    "servingRouteIds": servingRouteIds
  };

  static TransportStop fromJson(Map<String, dynamic> json) => TransportStop(
      id: json["id"],
      names: Map<String, String>.from(json["names"]),
      lat: json["lat"],
      lng: json["lng"],
      providerCode: json["providerCode"],
      servingRouteIds: List<String>.from(json["servingRouteIds"] ?? [])
  );
}