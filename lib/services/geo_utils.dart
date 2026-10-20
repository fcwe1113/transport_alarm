import 'dart:math';

/// The great-circle distance in metres between two points given in degrees.
double haversineDistanceMeters(double lat1, double lng1, double lat2, double lng2) {
  const earthRadiusMeters = 6371000.0;
  final dLat = _degToRad(lat2 - lat1);
  final dLng = _degToRad(lng2 - lng1);

  final a = sin(dLat / 2) * sin(dLat / 2) + cos(_degToRad(lat1)) * cos(_degToRad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
  final c = 2 * atan2(sqrt(a), sqrt(1 - a));
  return earthRadiusMeters * c;
}

double _degToRad(double deg) => deg * pi / 180;
