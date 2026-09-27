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

NextThresholdArming? armNextThreshold(BusAlarm alarm, int currentIndex, int minutesUntilArrival) {
  final nextIndex = currentIndex + 1;
  if (nextIndex >= alarm.thresholdStates.length) return null; // no next threshold
  final nextThreshold = alarm.thresholdStates[nextIndex];
  final minutesUntilNext = minutesUntilArrival - nextThreshold.minutesBeforeArrival;

  return NextThresholdArming(
      nextPingTime: DateTime.now().add(Duration(minutes: minutesUntilNext < 0 ? 0 : minutesUntilNext)),
      requiresAck: true,
      expireOn: _nextThresholdExpiry(alarm, nextIndex, minutesUntilArrival)
  );
}

AlarmDecision evaluateAlarm({required BusAlarm alarm, required int? minutesUntilArrival}) {
  final activeIndex = alarm.thresholdStates.indexWhere((t) => t.outcome == ThresholdOutcome.pending || t.outcome == ThresholdOutcome.ringing);

  // all thresholds came and went
  if (activeIndex == -1) {
    return AlarmDecision(action: AlarmAction.doNothing, updatedAlarm: alarm);
  }

  final threshold = alarm.thresholdStates[activeIndex];

  // no valid busses found
  if (minutesUntilArrival == null) { // todo set no bus found retry in 1/4 of active window or 30mins, whichever's lower
    final fallbackWait = const Duration(minutes: 5);
    return AlarmDecision(action: AlarmAction.scheduleNextPing, updatedAlarm: alarm, nextPingTime: DateTime.now().add(fallbackWait));
  }

  // threshold reached
  if (minutesUntilArrival <= threshold.minutesBeforeArrival) {
    final updateStates = List<ThresholdState>.from(alarm.thresholdStates);
    for (var i = 0; i < activeIndex; i++) {
      if (updateStates[i].outcome == ThresholdOutcome.ringing || updateStates[i].outcome == ThresholdOutcome.pending) {
        updateStates[i] = updateStates[i].copyWith(outcome: ThresholdOutcome.superseded);
      }
    }

    final newRingCount = threshold.ringCount + 1;
    final retriesExhausted = newRingCount >= alarm.maxRingsPerThreshold;

    updateStates[activeIndex] = threshold.copyWith(outcome: retriesExhausted ? ThresholdOutcome.missed : ThresholdOutcome.ringing, ringCount: newRingCount + 1);

    final updatedAlarm = alarm.copyWith(thresholdStates: updateStates);

    if (!retriesExhausted) return AlarmDecision(action: AlarmAction.ring, updatedAlarm: updatedAlarm);

    final nextArming = armNextThreshold(updatedAlarm, activeIndex, minutesUntilArrival);
    return AlarmDecision(action: AlarmAction.ring, updatedAlarm: updatedAlarm, nextPingTime: nextArming?.nextPingTime, nextPingRequiresAck: nextArming?.requiresAck ?? false, expireOn: nextArming?.expireOn);
  }

  final minutesUntilThreshold = minutesUntilArrival - threshold.minutesBeforeArrival;

  // not yet at threshold
  if (minutesUntilThreshold > 5) {
    final halfway = Duration(minutes: (minutesUntilThreshold / 2).round());
    return AlarmDecision(action: AlarmAction.scheduleNextPing, updatedAlarm: alarm, nextPingTime: DateTime.now().add(halfway));
  } else {
    return AlarmDecision(action: AlarmAction.scheduleNextPing, updatedAlarm: alarm, nextPingTime: DateTime.now().add(Duration(minutes: minutesUntilThreshold)), nextPingRequiresAck: true, expireOn: _nextThresholdExpiry(alarm, activeIndex, minutesUntilArrival));
  }
}

class NextThresholdArming {
  final DateTime nextPingTime;
  final bool requiresAck;
  final DateTime? expireOn;
  const NextThresholdArming({required this.nextPingTime, required this.requiresAck, required this.expireOn});
}

DateTime? _nextThresholdExpiry(BusAlarm alarm, int activeIndex, int minutesUntilArrival) {
  if (activeIndex + 1 >= alarm.thresholdStates.length) return DateTime.now().add(Duration(minutes: alarm.maxRingsPerThreshold)); // activeIndex is the last threshold

  final nextThreshold = alarm.thresholdStates[activeIndex + 1];
  final minutesUntilNextThreshold = minutesUntilArrival - nextThreshold.minutesBeforeArrival;
  return DateTime.now().add(Duration(minutes: minutesUntilNextThreshold, seconds: -30));
}