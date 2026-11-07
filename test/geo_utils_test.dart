import 'package:flutter_test/flutter_test.dart';
import 'package:transport_alarm/services/geo_utils.dart';

void main() {
  test('the same point is no distance away', () {
    expect(haversineDistanceMeters(53.48, -2.24, 53.48, -2.24), 0);
  });

  test('one degree of latitude is about 111 km', () {
    expect(haversineDistanceMeters(0, 0, 1, 0), closeTo(111195, 10));
  });

  test('a known distance: Manchester Piccadilly to Manchester Victoria', () {
    // About 1.3 km apart.
    final distance = haversineDistanceMeters(53.4774, -2.2309, 53.4875, -2.2425);
    expect(distance, closeTo(1350, 50));
  });

  test("is the same both ways", () {
    expect(
      haversineDistanceMeters(22.3, 114.17, 22.28, 114.16),
      closeTo(haversineDistanceMeters(22.28, 114.16, 22.3, 114.17), 1e-6),
    );
  });
}
