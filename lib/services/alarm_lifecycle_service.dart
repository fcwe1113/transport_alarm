import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:transport_alarm/models/transport_alarm.dart';
import 'package:transport_alarm/services/alarm_server_service.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/services/apns_token_service.dart';
import 'package:transport_alarm/services/device_token_service.dart';
import 'package:transport_alarm/services/ping_watchdog_service.dart';
import 'package:transport_alarm/transit/models/repeat_pattern.dart';
import 'package:transport_alarm/transit/models/threshold_state.dart';
import 'package:transport_alarm/services/android_alarm_coordinator.dart';

///
class AlarmLifecycleService {
  final AlarmStorageService _storage;
  final AlarmServerService _server;

  const AlarmLifecycleService({required this._storage, required this._server});

  static AppLifecycleListener? _resyncListener;
  static Future<void> _resyncing = Future.value();
  static String? _lastSyncedToken;
  static DateTime? _lastSyncedAt;

  /// iOS: keeps every enabled alarm's server ping pointed at this device's
  /// current push token, and replaces any ping the server has dropped. Runs
  /// now, whenever iOS issues a token, and when the app comes back to the
  /// foreground, which is what the ping watchdog notification asks for.
  static void startIosPingResync() {
    if (!Platform.isIOS || _resyncListener != null) return;
    final lifecycle = AlarmLifecycleService(storage: AlarmStorageService(), server: AlarmServerService());
    void run() {
      _resyncing = _resyncing.then((_) async {
        final token = await DeviceTokenService.getToken();
        if (token == null) return;
        // Resuming often shouldn't call the server for every alarm each time.
        final recent = _lastSyncedAt != null && DateTime.now().difference(_lastSyncedAt!) < const Duration(minutes: 5);
        if (token == _lastSyncedToken && recent) return;
        await lifecycle.resyncPings(token);
        _lastSyncedToken = token;
        _lastSyncedAt = DateTime.now();
      }).catchError((_) {});
    }
    ApnsTokenService.instance.onToken.listen((_) => run());
    _resyncListener = AppLifecycleListener(onResume: run);
    run();
  }

  /// Moves each enabled alarm's ping to [deviceToken], scheduling a new ping
  /// for any alarm without one or whose ping the server no longer has (its
  /// chain of pings stopped). The alarm's progress is kept, so the
  /// notification extension carries on from where it stopped.
  Future<void> resyncPings(String deviceToken) async {
    final alarms = await _storage.loadAlarms();
    for (final alarm in alarms.where((a) => a.enabled)) {
      try {
        final pingId = alarm.pingId;
        final secret = alarm.pingSecret;
        if (pingId != null && secret != null &&
            await _server.updateToken(pingId: pingId, secret: secret, deviceToken: deviceToken)) {
          continue;
        }
        final scheduled = await _schedulePing(alarm);
        if (scheduled.pingId != pingId) await _storage.updateAlarm(scheduled);
      } catch (_) {
        // Tried again on the next launch or resume.
      }
    }
  }

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
      final existing = (await _storage.loadAlarms())
          .where((saved) => saved.id == alarm.id)
          .firstOrNull;
      // An edit replaces the saved alarm only after its new ping is
      // scheduled, so a failure leaves the old alarm working.
      final scheduled = await _schedulePing(alarm);
      if (existing == null) {
        await _storage.addAlarm(scheduled);
      } else {
        // Cancel while the old ping is still saved: cancelPing reads its
        // secret from storage.
        if (existing.pingId != null && existing.pingId != scheduled.pingId) {
          try {
            await _server.cancelPing(existing.pingId!);
          } catch (_) {
            // The extension acknowledges a ping no saved alarm owns.
          }
        }
        await _storage.updateAlarm(scheduled);
      }
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
        await PingWatchdogService.disarm(alarmId);
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
    await PingWatchdogService.disarm(alarmId);
    await _storage.deleteAlarm(alarmId);
  }

  Future<void> handleOccurenceConcluded(TransportAlarm alarm) async {
    if (!_allThresholdsConcluded(alarm)) return;

    if (alarm.repeat.frequency == RepeatFrequency.none){
      if (alarm.pingId != null) {
        await _server.cancelPing(alarm.pingId!); // todo check if can null ping id on last ping given server will delete ping entry on expiry
      }
      await PingWatchdogService.disarm(alarm.id);
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
    final scheduledTime = _firstPingTime(alarm);

    final ping = await _server.schedule(deviceToken: deviceToken, scheduledTime: scheduledTime, requireAck: false);
    if (ping == null) return alarm;
    await PingWatchdogService.arm(alarm.id, scheduledTime);
    return alarm.copyWith(pingId: ping.id, pingSecret: ping.secret);
  }

  /// When the first ping should arrive: shortly if the window is open now,
  /// otherwise at the next window start on a day the alarm repeats on.
  DateTime _firstPingTime(TransportAlarm alarm) {
    final now = DateTime.now();
    if (alarm.isWithinWindow(TimeOfDay.now())) {
      return now.add(const Duration(seconds: 10));
    }
    for (var offset = 0; offset <= 370; offset++) {
      final day = DateTime(now.year, now.month, now.day + offset);
      final start = DateTime(
        day.year,
        day.month,
        day.day,
        alarm.windowStart.hour,
        alarm.windowStart.minute,
      );
      if (start.isAfter(now) && _repeatsOn(alarm.repeat, day)) return start;
    }
    return now.add(const Duration(seconds: 10));
  }

  bool _repeatsOn(RepeatPattern repeat, DateTime day) {
    switch (repeat.frequency) {
      case RepeatFrequency.none:
      case RepeatFrequency.daily:
        return true;
      case RepeatFrequency.weekly:
        return (repeat.weekdays ?? const []).contains(day.weekday);
      case RepeatFrequency.monthly:
        return (repeat.dayOfMonth ?? const []).contains(day.day);
    }
  }

  bool _allThresholdsConcluded(TransportAlarm alarm) {
    return alarm.thresholdStates.every((t) => t.outcome == ThresholdOutcome.acknowledged || t.outcome == ThresholdOutcome.superseded || t.outcome == ThresholdOutcome.missed);
  }

  Future<TransportAlarm> _schedulePingForNextOccurrence(TransportAlarm alarm) async {
    final deviceToken = await DeviceTokenService.getToken();
    if (deviceToken == null) return alarm;

    final nextDate = _computeNextOccurrenceDate(alarm.repeat);
    final scheduledTime = DateTime(nextDate.year, nextDate.month, nextDate.day, alarm.windowStart.hour, alarm.windowStart.minute);
    final ping = await _server.schedule(deviceToken: deviceToken, scheduledTime: scheduledTime, requireAck: false);
    if (ping == null) return alarm;
    await PingWatchdogService.arm(alarm.id, scheduledTime);
    return alarm.copyWith(pingId: ping.id, pingSecret: ping.secret);
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
