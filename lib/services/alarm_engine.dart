import 'package:transport_alarm/models/bus_alarm.dart';
import 'package:transport_alarm/transit/models/threshold_state.dart';

enum AlarmAction { ring, scheduleNextPing, doNothing }

class AlarmDecision {
  final AlarmAction action;
  final BusAlarm updatedAlarm; // to update pingid/thresholdStates
  final DateTime? nextPingTime; // set when action == scheduleNextPing
  final bool nextPingRequiresAck;
  final DateTime? expireOn;

  const AlarmDecision({required this.action, required this.updatedAlarm, this.nextPingTime, this.nextPingRequiresAck = false, this.expireOn});
}

AlarmDecision evaluateAlarm({required BusAlarm alarm, required int? minutesUntilArrival}) {
  final activeIndex = alarm.thresholdStates.indexWhere((t) => t.outcome == ThresholdOutcome.pending || t.outcome == ThresholdOutcome.ringing);

  // all thresholds came and went
  if (activeIndex == -1) {
    return AlarmDecision(action: AlarmAction.doNothing, updatedAlarm: alarm);
  }

  final threshold = alarm.thresholdStates[activeIndex];

  // A ringing threshold repeats on the existing ping every minute until the
  // user acknowledges it, even when the live ETA is unavailable.
  if (threshold.outcome == ThresholdOutcome.ringing) {
    final updatedStates = List<ThresholdState>.from(alarm.thresholdStates);
    updatedStates[activeIndex] = threshold.copyWith(ringCount: threshold.ringCount + 1);
    return AlarmDecision(
      action: AlarmAction.ring,
      updatedAlarm: alarm.copyWith(thresholdStates: updatedStates),
      nextPingTime: DateTime.now().add(const Duration(minutes: 1)),
      nextPingRequiresAck: true,
    );
  }

  // no valid buses found
  if (minutesUntilArrival == null) { // todo set no bus found retry in 1/4 of active window or 30mins, whichever's lower
    final fallbackWait = const Duration(minutes: 5);
    return AlarmDecision(action: AlarmAction.scheduleNextPing, updatedAlarm: alarm, nextPingTime: DateTime.now().add(fallbackWait));
  }

  // threshold reached
  if (minutesUntilArrival <= threshold.minutesBeforeArrival) {
    final updateStates = List<ThresholdState>.from(alarm.thresholdStates);
    updateStates[activeIndex] = threshold.copyWith(
      outcome: ThresholdOutcome.ringing,
      ringCount: threshold.ringCount + 1,
    );
    return AlarmDecision(
      action: AlarmAction.ring,
      updatedAlarm: alarm.copyWith(thresholdStates: updateStates),
      nextPingTime: DateTime.now().add(const Duration(minutes: 1)),
      nextPingRequiresAck: true,
    );
  }

  final minutesUntilThreshold = minutesUntilArrival - threshold.minutesBeforeArrival;

  // not yet at threshold
  if (minutesUntilThreshold > 5) {
    final halfway = Duration(minutes: (minutesUntilArrival / 2).round());
    return AlarmDecision(action: AlarmAction.scheduleNextPing, updatedAlarm: alarm, nextPingTime: DateTime.now().add(halfway));
  } else {
    return AlarmDecision(action: AlarmAction.scheduleNextPing, updatedAlarm: alarm, nextPingTime: DateTime.now().add(Duration(minutes: minutesUntilThreshold)), nextPingRequiresAck: true, expireOn: _nextThresholdExpiry(alarm, activeIndex, minutesUntilArrival));
  }
}

DateTime? _nextThresholdExpiry(BusAlarm alarm, int activeIndex, int minutesUntilArrival) {
  if (activeIndex + 1 >= alarm.thresholdStates.length) return DateTime.now().add(Duration(minutes: alarm.maxRingsPerThreshold)); // activeIndex is the last threshold

  final nextThreshold = alarm.thresholdStates[activeIndex + 1];
  final minutesUntilNextThreshold = minutesUntilArrival - nextThreshold.minutesBeforeArrival;
  return DateTime.now().add(Duration(minutes: minutesUntilNextThreshold, seconds: -30));
}
