import 'package:flutter_test/flutter_test.dart';
import 'package:transport_alarm/transit/models/transport_route.dart';

void main() {
  TransportRoute route(String number, String destination, {String bound = 'O', Map<String, String>? destinations}) =>
      TransportRoute(
        id: 'kmb:${number}_$bound',
        names: {'en': number},
        routeNumber: number,
        bound: bound,
        originText: const {'en': 'Origin'},
        destinationText: destinations ?? {'en': destination},
        providerCode: 'kmb',
        locale: 'hk',
      );

  test('dedupeByRouteNumber keeps the first route of each number', () {
    final routes = TransportRoute.dedupeByRouteNumber([
      route('1A', 'Star Ferry'),
      route('1A', 'Sau Mau Ping', bound: 'I'),
      route('2', 'Cheung Sha Wan'),
    ]);
    expect(routes.map((r) => r.routeNumber), ['1A', '2']);
    expect(routes.first.destinationNameFor('en'), 'Star Ferry');
  });

  test('dedupeByRouteAndDestination keeps each direction once', () {
    final routes = TransportRoute.dedupeByRouteAndDestination([
      route('1A', 'Star Ferry'),
      route('1A', 'Star Ferry'),
      route('1A', 'Sau Mau Ping', bound: 'I'),
    ]);
    expect(routes.map((r) => r.destinationNameFor('en')), ['Star Ferry', 'Sau Mau Ping']);
  });

  test('dedupeByRouteAndDestination compares destinations in the given language', () {
    // The same in English, different in Chinese.
    final routes = TransportRoute.dedupeByRouteAndDestination([
      route('5', '', destinations: {'en': 'Central', 'zh-Hant': '中環'}),
      route('5', '', destinations: {'en': 'Central', 'zh-Hant': '中環碼頭'}),
    ], languageCode: 'zh-Hant');
    expect(routes, hasLength(2));
  });

  test('destinationNameFor falls back to English', () {
    expect(route('3', 'Jordan').destinationNameFor('ja'), 'Jordan');
  });
}
