import 'package:flutter_test/flutter_test.dart';
import 'package:transport_alarm/models/scheduled_departure.dart';
import 'package:transport_alarm/transit/models/live_eta.dart';
import 'package:transport_alarm/transit/services/arrival_resolver.dart';

void main() {
  ScheduledDeparture departure(String tripId) => ScheduledDeparture(
    routeShortName: '1',
    arrivalTime: '08:00:00',
    destination: const {'en': 'Town'},
    tripId: tripId,
    locale: 'gb',
  );

  LiveEta live({String? tripId, bool hasPassed = false}) => LiveEta(
    routeNumber: '1',
    bound: '',
    destination: const {'en': 'Town'},
    etaTime: hasPassed ? null : DateTime.now(),
    tripId: tripId,
    hasPassed: hasPassed,
  );

  test('drops timetabled trips a live feed is tracking', () {
    final kept = withoutLiveTrips([departure('a'), departure('b'), departure('c')], [live(tripId: 'b')]);
    expect(kept.map((d) => d.tripId), ['a', 'c']);
  });

  test('also drops trips whose bus has already passed the stop', () {
    final kept = withoutLiveTrips([departure('a'), departure('b')], [live(tripId: 'a', hasPassed: true)]);
    expect(kept.map((d) => d.tripId), ['b']);
  });

  test('keeps everything when live buses carry no trip IDs (TfL, KMB)', () {
    final scheduled = [departure('a'), departure('b')];
    expect(withoutLiveTrips(scheduled, [live()]), scheduled);
  });
}
