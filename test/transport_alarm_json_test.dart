import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_test/flutter_test.dart';
import 'package:transport_alarm/models/alarm_route_config.dart';
import 'package:transport_alarm/models/transport_alarm.dart';
import 'package:transport_alarm/services/arrival_lock.dart';
import 'package:transport_alarm/transit/models/repeat_pattern.dart';
import 'package:transport_alarm/transit/models/threshold_state.dart';

void main() {
  final alarm = TransportAlarm(
    id: '1793899552092',
    gtfsStopId: '1800SB12345',
    routeApiConfigs: const [
      AlarmRouteConfig(routeNumber: '533', mode: 'bus', providerCode: 'bods', apiUrl: 'https://example.invalid'),
    ],
    localeCode: 'gb',
    routeNumbers: const {'533': {'en': 'Bolton'}},
    windowStart: const TimeOfDay(hour: 23, minute: 50),
    windowEnd: const TimeOfDay(hour: 0, minute: 20),
    thresholdStates: const [
      ThresholdState(minutesBeforeArrival: 10, ringCount: 2, outcome: ThresholdOutcome.acknowledged),
      ThresholdState(minutesBeforeArrival: 5),
    ],
    repeat: const RepeatPattern(frequency: RepeatFrequency.weekly, weekdays: [1, 5]),
    liveOnly: true,
    message: 'Wake up!',
    lockedArrival: LockedArrival.fromCandidate(
      ArrivalCandidate(arrival: DateTime(2026, 11, 9, 0, 5), isLive: true, routeNumber: '533', tripId: 't1'),
      DateTime(2026, 11, 8, 23, 40),
    ),
    skippedArrivals: const ['trip:t0'],
    nextBusAfterEpochSeconds: 123,
    checkLeadMinutes: 15,
    pingId: 'p',
    pingSecret: 's',
  );

  test('every field survives a JSON round trip', () {
    final restored = TransportAlarm.fromJson(alarm.toJson());
    expect(restored.toJson(), alarm.toJson());
  });

  test('saves times as minutes past midnight, which the iOS extension reads', () {
    final json = alarm.toJson();
    expect(json['windowStart'], 23 * 60 + 50);
    expect(json['windowEnd'], 20);
    expect(json['windowVersion'], 2);
  });

  test('copyWith can clear the lock and the Next bus floor', () {
    final cleared = alarm.copyWith(clearLockedArrival: true, clearNextBusAfter: true, skippedArrivals: const []);
    expect(cleared.lockedArrival, isNull);
    expect(cleared.nextBusAfterEpochSeconds, isNull);
    expect(cleared.skippedArrivals, isEmpty);
    // Everything else is kept.
    expect(cleared.checkLeadMinutes, 15);
    expect(cleared.pingSecret, 's');
  });

  test('largestThresholdMinutes is the largest minutes-before-arrival', () {
    expect(alarm.largestThresholdMinutes, 10);
  });

  test('a one-off alarm with no repeat reads with defaults for newer fields', () {
    final minimal = TransportAlarm.fromJson({
      'id': '1',
      'gtfsStopId': 'stop',
      'routeNumbers': {'1': {'en': 'Town'}},
      'windowStart': 480,
      'windowEnd': 510,
      'maxRingsPerThreshold': 10,
      'thresholdStates': [{'minutesBeforeArrival': 5, 'ringCount': 0, 'outcome': 'pending'}],
      'repeat': {'frequency': 'none'},
      'liveOnly': false,
      'message': '',
      'enabled': true,
      'windowVersion': 2,
    });
    expect(minimal.localeCode, 'hk');
    expect(minimal.routeApiConfigs, isEmpty);
    expect(minimal.checkLeadMinutes, 10);
    expect(minimal.lockedArrival, isNull);
    expect(minimal.spent, isFalse);
  });
}
