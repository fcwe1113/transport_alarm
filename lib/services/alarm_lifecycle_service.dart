import 'dart:io';

import 'package:flutter/material.dart';
import 'package:transport_alarm/models/transport_alarm.dart';
import 'package:transport_alarm/services/alarm_server_service.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/services/device_token_service.dart';
import 'package:transport_alarm/transit/models/repeat_pattern.dart';
import 'package:transport_alarm/transit/models/threshold_state.dart';
import 'package:transport_alarm/services/android_alarm_coordinator.dart';

///
class AlarmLifecycleService {
  final AlarmStorageService _storage;
  final AlarmServerService _server;

  const AlarmLifecycleService({required this._storage, required this._server});

  Future<AlarmActionResult> createAlarm(TransportAlarm alarm) async {
    if (Platform.isAndroid) {
      final existing = (await _storage.loadAlarms())
          .where((saved) => saved.id == alarm.id)
          .firstOrNull;
      try {
        if (existing == null) {
          await _storage.addAlarm(alarm);
        } else {
          if (existing.pingId != null) {
            try {
              await _server.cancelPing(existing.pingId!);
            } catch (_) {
              // Local Android alarms do not depend on the old server ping.
            }
          }
          await _storage.updateAlarm(alarm);
        }
        await AndroidAlarmCoordinator(_storage).startOrSchedule(alarm);
        return const AlarmActionResult.success();
      } catch (e) {
        if (existing == null) {
          await AndroidAlarmCoordinator(_storage).disable(alarm.id);
          await _storage.deleteAlarm(alarm.id);
        } else {
          await _storage.updateAlarm(existing);
          if (!e.toString().contains('Allow Transport Alarm')) {
            try {
              await AndroidAlarmCoordinator(_storage).startOrSchedule(existing);
            } catch (_) {
              // Preserve the prior alarm if Android refuses to rearm it.
            }
          }
        }
        return AlarmActionResult.failure(e.toString());
      }
    }
    try {
      final scheduled = await _schedulePing(alarm);
      await _storage.addAlarm(scheduled);
      return const AlarmActionResult.success();
    } catch (e) {
      return AlarmActionResult.failure(e.toString());
    }
  }

  Future<AlarmActionResult> setEnabled(String alarmId, bool enabled) async { // todo show popup if a bus is found within the threshold, user can skip the bus or skip the alarm state to cathc the bus
    final alarms = await _storage.loadAlarms();
    final alarm = alarms.where((a) => a.id == alarmId).firstOrNull;
    if (alarm == null) return AlarmActionResult.failure("Alarm not found");

    try {
      if (enabled) {
        final reenabled = alarm.copyWith(
          enabled: true,
          spent: false,
          thresholdStates: alarm.thresholdStates
              .map((t) => ThresholdState(minutesBeforeArrival: t.minutesBeforeArrival))
              .toList(),
          clearLastEstimatedMinutesUntilThreshold: true,
          clearPingId: Platform.isAndroid,
        );
        if (Platform.isAndroid) {
          if (alarm.pingId != null) {
            try {
              await _server.cancelPing(alarm.pingId!);
            } catch (_) {
              // A legacy server ping is independent of the new local schedule.
            }
          }
          await _storage.updateAlarm(reenabled);
          try {
            await AndroidAlarmCoordinator(_storage).startOrSchedule(reenabled);
          } catch (e) {
            await _storage.updateAlarm(
              reenabled.copyWith(enabled: false, clearAndroidOccurrence: true),
            );
            return AlarmActionResult.failure(e.toString());
          }
          return const AlarmActionResult.success();
        }
        final scheduled = await _schedulePing(reenabled);
        await _storage.updateAlarm(scheduled);
      } else {
        if (Platform.isAndroid) {
          await AndroidAlarmCoordinator(_storage).disable(alarmId);
        }
        if (alarm.pingId != null) {
          await _server.cancelPing(alarm.pingId!);
        }
        await _storage.updateAlarm(
          alarm.copyWith(
            enabled: false,
            clearPingId: true,
            clearAndroidOccurrence: true,
            clearAndroidFallbackArrival: true,
          ),
        );
      }
      return AlarmActionResult.success();
    } catch (e) {
      return AlarmActionResult.failure(e.toString());
    }
  }

  Future<void> deleteAlarm(String alarmId) async {
    final alarms = await _storage.loadAlarms();
    final alarm = alarms.where((a) => a.id == alarmId).firstOrNull;
    if (Platform.isAndroid) {
      await AndroidAlarmCoordinator(_storage).disable(alarmId);
    }
    if (alarm?.pingId != null) {
      await _server.cancelPing(alarm!.pingId!);
    }
    await _storage.deleteAlarm(alarmId);
  }

  Future<void> handleOccurenceConcluded(TransportAlarm alarm) async {
    if (!_allThresholdsConcluded(alarm)) return;

    if (alarm.repeat.frequency == RepeatFrequency.none){
      if (alarm.pingId != null) {
        await _server.cancelPing(alarm.pingId!); // todo check if can null ping id on last ping given server will delete ping entry on expiry
      }
      await _storage.updateAlarm(alarm.copyWith(enabled: false, pingId: null, spent: true));
      return;
    }

    final resetAlarm = alarm.copyWith(
      spent: true,
      clearLastEstimatedMinutesUntilThreshold: true,
    );
    final scheduled = await _schedulePingForNextOccurrence(resetAlarm);
    return _storage.updateAlarm(scheduled);
  }

  Future<TransportAlarm> _schedulePing(TransportAlarm alarm) async {
    final deviceToken = await DeviceTokenService.getToken();
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

  bool _allThresholdsConcluded(TransportAlarm alarm) {
    return alarm.thresholdStates.every((t) => t.outcome == ThresholdOutcome.acknowledged || t.outcome == ThresholdOutcome.superseded || t.outcome == ThresholdOutcome.missed);
  }

  Future<TransportAlarm> _schedulePingForNextOccurrence(TransportAlarm alarm) async {
    final deviceToken = await DeviceTokenService.getToken();
    if (deviceToken == null) return alarm;

    final nextDate = _computeNextOccurrenceDate(alarm.repeat);
    final scheduledTime = DateTime(nextDate.year, nextDate.month, nextDate.day, alarm.windowStart.hour, alarm.windowStart.minute);
    final pingId = await _server.schedule(deviceToken: deviceToken, scheduledTime: scheduledTime, requireAck: false);
    return alarm.copyWith(pingId: pingId);
  }

  DateTime _computeNextOccurrenceDate(RepeatPattern repeat) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (repeat.frequency) {
      case RepeatFrequency.daily:
        return DateTime(today.year, today.month, today.day + 1);
      case RepeatFrequency.weekly:
        final weekdays = repeat.weekdays ?? [];
        for (var i = 1; i <= 7; i++) {
          final candidate = DateTime(today.year, today.month, today.day + i);
          if (weekdays.contains(candidate.weekday)) return candidate;
        }
        return DateTime(today.year, today.month, today.day + 7); // fallback if no weekdays selected
      case RepeatFrequency.monthly:
        final days = repeat.dayOfMonth ?? [];
        for (var i = 1; i <= 31; i++) {
          final candidate = DateTime(today.year, today.month, today.day + i);
          if (days.contains(candidate.day)) return candidate;
        }
        return DateTime(today.year, today.month + 1, today.day); // fallback
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
