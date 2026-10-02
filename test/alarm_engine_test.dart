import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transport_alarm/models/transport_alarm.dart';
import 'package:transport_alarm/services/alarm_engine.dart';
import 'package:transport_alarm/transit/models/threshold_state.dart';

void main() {
  test("rings when minutesUntilArrival reaches the threshold", () {
    final alarm = TransportAlarm(
        id: "test-1",
        gtfsStopId: "stop-1",
        routeNumbers: ["1A"],
        windowStart: const TimeOfDay(hour: 8, minute: 0),
        windowEnd: const TimeOfDay(hour: 9, minute: 0),
        thresholdStates: [const ThresholdState(minutesBeforeArrival: 5)],
        message: "notification text"
    );

    final decision = evaluateAlarm(alarm: alarm, minutesUntilArrival: 5);

    expect(decision.action, AlarmAction.ring);
    expect(decision.updatedAlarm.thresholdStates.first.outcome, ThresholdOutcome.ringing);

  });

  test("schedules a re-check when far from threshold", () {
    final alarm = TransportAlarm(
        id: "test-2",
        gtfsStopId: "stop-1",
        routeNumbers: ["1A"],
        windowStart: const TimeOfDay(hour: 8, minute: 0),
        windowEnd: const TimeOfDay(hour: 9, minute: 0),
        thresholdStates: [const ThresholdState(minutesBeforeArrival: 5)],
        message: "notification text"
    );

    final decision = evaluateAlarm(alarm: alarm, minutesUntilArrival: 20);

    expect(decision.action, AlarmAction.scheduleNextPing);
    expect(decision.nextPingRequiresAck, false);

  });

  test("exhausting retries marks threshold missed and arms next one", () {
    final alarm = TransportAlarm(
        id: "test-3",
        gtfsStopId: "stop-1",
        routeNumbers: ["1A"],
        windowStart: const TimeOfDay(hour: 8, minute: 0),
        windowEnd: const TimeOfDay(hour: 9, minute: 0),
        maxRingsPerThreshold: 3,
        thresholdStates: [
          const ThresholdState(minutesBeforeArrival: 10, ringCount: 2, outcome: ThresholdOutcome.ringing),
          const ThresholdState(minutesBeforeArrival: 5)
        ],
        message: "notification text"
    );

    final decision = evaluateAlarm(alarm: alarm, minutesUntilArrival: 10);

    expect(decision.updatedAlarm.thresholdStates[0].outcome, ThresholdOutcome.missed);
    expect(decision.nextPingTime, isNotNull);

  });

  test("retries running up to the next threshold", () {
    final alarm = TransportAlarm(
        id: "test-4",
        gtfsStopId: "stop-1",
        routeNumbers: ["1A"],
        windowStart: const TimeOfDay(hour: 8, minute: 0),
        windowEnd: const TimeOfDay(hour: 9, minute: 0),
        thresholdStates: [
          const ThresholdState(minutesBeforeArrival: 10, ringCount: 2, outcome: ThresholdOutcome.ringing),
          const ThresholdState(minutesBeforeArrival: 5)
        ],
        message: "notification text"
    );

    final decision = evaluateAlarm(alarm: alarm, minutesUntilArrival: 6);

    expect(decision.updatedAlarm.thresholdStates[0].outcome, ThresholdOutcome.superseded);
    // expect(decision.nextPingTime, isNotNull);

  });
}
