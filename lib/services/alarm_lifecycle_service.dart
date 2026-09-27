import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:transport_alarm/models/bus_alarm.dart';
import 'package:transport_alarm/services/alarm_server_service.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/transit/models/repeat_pattern.dart';
import 'package:transport_alarm/transit/models/threshold_state.dart';

class AlarmLifecycleService {
  final AlarmStorageService _storage;
  final AlarmServerService _server;

  const AlarmLifecycleService({required this._storage, required this._server});

  Future<AlarmActionResult> createAlarm(BusAlarm alarm) async {
    try {
      final scheduled = await _schedulePing(alarm);
      await _storage.addAlarm(scheduled);
      return const AlarmActionResult.success();
    } catch (e) {
      return AlarmActionResult.failure(e.toString());
    }
  }

  Future<AlarmActionResult> setEnabled(String alarmId, bool enabled) async { // todo ignore buses that are arriving before first threshold
    final alarms = await _storage.loadAlarms();
    final alarm = alarms.where((a) => a.id == alarmId).firstOrNull;
    if (alarm == null) return AlarmActionResult.failure("Alarm not found");

    try {
      if (enabled) {
        final scheduled = await _schedulePing(alarm.copyWith(enabled: true));
        await _storage.updateAlarm(scheduled);
      } else {
        if (alarm.pingId != null) {
          await _server.cancelPing(alarm.pingId!);
        }
        await _storage.updateAlarm(alarm.copyWith(enabled: false, pingId: null));
      }
      return AlarmActionResult.success();
    } catch (e) {
      return AlarmActionResult.failure(e.toString());
    }
  }

  Future<void> deleteAlarm(String alarmId) async {
    final alarms = await _storage.loadAlarms();
    final alarm = alarms.where((a) => a.id == alarmId).firstOrNull;
    if (alarm?.pingId != null) {
      await _server.cancelPing(alarm!.pingId!);
    }
    await _storage.deleteAlarm(alarmId);
  }

  Future<void> handleOccurenceConcluded(BusAlarm alarm) async {
    if (!_allThresholdsConcluded(alarm)) return;

    if (alarm.repeat.frequency == RepeatFrequency.none){
      if (alarm.pingId != null) {
        await _server.cancelPing(alarm.pingId!); // todo check if can null ping id on last ping given server will delete ping entry on expiry
      }
      await _storage.updateAlarm(alarm.copyWith(enabled: false, pingId: null));
      return;
    }

    final resetStates = alarm.thresholdStates.map((t) => ThresholdState(minutesBeforeArrival: t.minutesBeforeArrival)).toList();
    final resetAlarm = alarm.copyWith(thresholdStates: resetStates);
    final scheduled = await _schedulePingForNextOccurrence(resetAlarm);
    return _storage.updateAlarm(scheduled);
  }

  Future<BusAlarm> _schedulePing(BusAlarm alarm) async {
    final deviceToken = await FirebaseMessaging.instance.getToken();
    if (deviceToken == null) return alarm; // no token yet
    final now = TimeOfDay.now();

    final scheduledTime = alarm.isWithinWindow(now) ? DateTime.now().add(Duration(seconds: 10)) : _todayAt(now);
    // if (scheduledTime.isBefore(DateTime.now())) return // todo api call arrival time if window already started

    final pingId = await _server.schedule(deviceToken: deviceToken, scheduledTime: scheduledTime, requireAck: false);
    return alarm.copyWith(pingId: pingId);
  }

  DateTime _todayAt(TimeOfDay time) {
    final now = DateTime.now();
    var result = DateTime(now.year, now.month, now.day, time.hour, time.minute, now.second + 5); // add 5 seconds because .isbefore() checks seconds as well
    if (result.isBefore(now)) result = result.add(Duration(days: 1));
    return result;
  }

  bool _allThresholdsConcluded(BusAlarm alarm) {
    return alarm.thresholdStates.every((t) => t.outcome == ThresholdOutcome.acknowledged || t.outcome == ThresholdOutcome.superseded || t.outcome == ThresholdOutcome.missed);
  }

  Future<BusAlarm> _schedulePingForNextOccurrence(BusAlarm alarm) async {
    final deviceToken = await FirebaseMessaging.instance.getToken();
    if (deviceToken == null) return alarm;

    final nextDate = _computeNextOccurrenceDate(alarm.repeat);
    final scheduledTime = DateTime(nextDate.year, nextDate.month, nextDate.day, alarm.windowStart.hour, alarm.windowStart.minute);
    final pingId = await _server.schedule(deviceToken: deviceToken, scheduledTime: scheduledTime, requireAck: false);
    return alarm.copyWith(pingId: pingId);
  }

  DateTime _computeNextOccurrenceDate(RepeatPattern repeat) {
    final now = DateTime.now();
    switch (repeat.frequency) {
      case RepeatFrequency.daily:
        return now.add(Duration(days: 1));
      case RepeatFrequency.weekly:
        final weekdays = repeat.weekdays ?? [];
        for (var i = 1; i <= 7; i++) {
          final candidate = now.add(Duration(days: i));
          if (weekdays.contains(candidate.weekday)) return candidate;
        }
        return now.add(Duration(days: 7)); // fallback if no weekdays selected
      case RepeatFrequency.monthly:
        final days = repeat.dayOfMonth ?? [];
        for (var i = 1; i <= 31; i++) {
          final candidate = now.add(Duration(days: i));
          if (days.contains(candidate.day)) return candidate;
        }
        return DateTime(now.year, now.month + 1, now.day); // fallback
      case RepeatFrequency.none:
        return now; // how did you get here lol
    }
  }
}

class AlarmActionResult {
  final bool succeeded;
  final String? errorMessage;
  const AlarmActionResult.success() : succeeded = true, errorMessage = null;
  const AlarmActionResult.failure(this.errorMessage) : succeeded = false;
}