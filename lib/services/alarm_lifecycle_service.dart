import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:transport_alarm/models/transport_alarm.dart';
import 'package:transport_alarm/services/alarm_server_service.dart';
import 'package:transport_alarm/services/alarm_storage_service.dart';
import 'package:transport_alarm/services/apns_token_service.dart';
import 'package:transport_alarm/services/app_group_storage.dart';
import 'package:transport_alarm/services/notification_service.dart';
import 'package:transport_alarm/services/orphaned_ping_store.dart';
import 'package:transport_alarm/services/ping_watchdog_service.dart';
import 'package:transport_alarm/transit/models/threshold_state.dart';
import 'package:transport_alarm/services/android_alarm_coordinator.dart';

/// Creates, edits, turns on and off, and deletes alarms, keeping each
/// platform's scheduling in step with storage: local alarms through
/// [AndroidAlarmCoordinator] on Android, and server pings on iOS.
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
        final token = await ApnsTokenService.instance.getToken();
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
  /// for any alarm without one, whose ping the server no longer has (its
  /// chain of pings stopped), or whose ping belongs to another phone (this
  /// one was restored from its backup). The alarm's progress is kept, so the
  /// notification extension carries on from where it stopped.
  Future<void> resyncPings(String deviceToken) async {
    await _cancelOrphanedPings();
    final alarms = await _storage.loadAlarms();
    final deviceId = await AppGroupStorage.deviceId();
    for (final alarm in alarms.where((a) => a.enabled)) {
      try {
        final pingId = alarm.pingId;
        final secret = alarm.pingSecret;
        if (pingId != null && secret != null && !await _pingBelongsToAnotherPhone(alarm) &&
            await _server.updateToken(pingId: pingId, secret: secret, deviceToken: deviceToken)) {
          // Pings from before owners were recorded belong to the phone that
          // first moves them.
          if (deviceId != null && alarm.pingDeviceId == null) {
            await _storage.setPingDevice(alarm.id, pingId, deviceId);
          }
          continue;
        }
        final scheduled = await _schedulePing(alarm);
        if (scheduled.pingId != pingId) await _storage.updateAlarm(scheduled);
      } catch (_) {
        // Tried again on the next launch or resume.
      }
    }
  }

  /// Saves a new alarm, or replaces the saved alarm with the same ID, and
  /// schedules it. On failure the previous version is left as it was.
  Future<AlarmActionResult> createAlarm(TransportAlarm alarm) async {
    final existing = await _find(alarm.id);
    return Platform.isAndroid
        ? _createAndroidAlarm(alarm, existing)
        : _createIosAlarm(alarm, existing);
  }

  Future<AlarmActionResult> _createAndroidAlarm(TransportAlarm alarm, TransportAlarm? existing) async {
    try {
      if (existing == null) {
        await _storage.addAlarm(alarm);
      } else {
        await _cancelPingIfAny(existing);
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

  Future<AlarmActionResult> _createIosAlarm(TransportAlarm alarm, TransportAlarm? existing) async {
    try {
      // An edit replaces the saved alarm only after its new ping is
      // scheduled, so a failure leaves the old alarm working.
      final scheduled = await _schedulePing(alarm);
      if (existing == null) {
        await _storage.addAlarm(scheduled);
      } else {
        // Cancel while the old ping is still saved: cancelPing reads its
        // secret from storage.
        if (existing.pingId != scheduled.pingId) await _cancelPingIfAny(existing);
        await _storage.updateAlarm(scheduled);
      }
      return const AlarmActionResult.success();
    } catch (e) {
      return AlarmActionResult.failure(e.toString());
    }
  }

  // todo show popup if a bus is found within the threshold, user can skip the bus or skip the alarm state to cathc the bus
  /// Turns an alarm on, starting its next occurrence afresh, or off.
  Future<AlarmActionResult> setEnabled(String alarmId, bool enabled) async {
    final alarm = await _find(alarmId);
    if (alarm == null) return AlarmActionResult.failure("Alarm not found");
    try {
      return enabled ? await _enable(alarm) : await _disable(alarm);
    } catch (e) {
      return AlarmActionResult.failure(e.toString());
    }
  }

  Future<AlarmActionResult> _enable(TransportAlarm alarm) async {
    final reenabled = alarm.copyWith(
      enabled: true,
      spent: false,
      thresholdStates: alarm.thresholdStates
          .map((t) => ThresholdState(minutesBeforeArrival: t.minutesBeforeArrival))
          .toList(),
      clearLastEstimatedMinutesUntilThreshold: true,
      clearIgnoreArrivalsBefore: true,
      clearPingId: Platform.isAndroid,
    );
    if (!Platform.isAndroid) {
      await _storage.updateAlarm(await _schedulePing(reenabled));
      return const AlarmActionResult.success();
    }

    await _cancelPingIfAny(alarm);
    await _storage.updateAlarm(reenabled);
    try {
      // Asked here, where the app is on screen; the coordinator only checks.
      await NotificationService.requestExactAlarms();
      await AndroidAlarmCoordinator(_storage).startOrSchedule(reenabled);
    } catch (e) {
      await _storage.updateAlarm(
        reenabled.copyWith(enabled: false, clearAndroidOccurrence: true),
      );
      return AlarmActionResult.failure(e.toString());
    }
    return const AlarmActionResult.success();
  }

  Future<AlarmActionResult> _disable(TransportAlarm alarm) async {
    if (Platform.isAndroid) {
      await AndroidAlarmCoordinator(_storage).disable(alarm.id);
    }
    await _cancelPingIfAny(alarm);
    await PingWatchdogService.disarm(alarm.id);
    await _storage.updateAlarm(
      alarm.copyWith(
        enabled: false,
        clearPingId: true,
        clearAndroidOccurrence: true,
        clearAndroidFallbackArrival: true,
      ),
    );
    return const AlarmActionResult.success();
  }

  Future<void> deleteAlarm(String alarmId) async {
    final alarm = await _find(alarmId);
    if (Platform.isAndroid) {
      await AndroidAlarmCoordinator(_storage).disable(alarmId);
    }
    await _cancelPingIfAny(alarm);
    await PingWatchdogService.disarm(alarmId);
    await _storage.deleteAlarm(alarmId);
  }

  /// Asks the server to drop [alarm]'s ping, if it has one. A failure, such
  /// as being offline, doesn't stop the change: the ping is kept in
  /// [OrphanedPingStore], so the notification extension acknowledges it
  /// when it arrives and [resyncPings] retries the cancel. Android alarms
  /// don't use server pings at all.
  Future<void> _cancelPingIfAny(TransportAlarm? alarm) async {
    final pingId = alarm?.pingId;
    final secret = alarm?.pingSecret;
    if (pingId == null || secret == null) return;
    // Another phone's ping keeps its alarms going there.
    if (await _pingBelongsToAnotherPhone(alarm!)) return;
    try {
      await _server.cancelPing(pingId: pingId, secret: secret);
    } catch (e) {
      debugPrint("Could not cancel server ping $pingId: $e");
      if (Platform.isIOS) await OrphanedPingStore.add(pingId, secret);
    }
  }

  /// Retries cancelling the pings [_cancelPingIfAny] couldn't.
  Future<void> _cancelOrphanedPings() async {
    for (final MapEntry(key: pingId, value: secret) in (await OrphanedPingStore.load()).entries) {
      try {
        await _server.cancelPing(pingId: pingId, secret: secret);
        await OrphanedPingStore.remove(pingId);
      } catch (_) {
        // Still offline; tried again on the next launch or resume.
      }
    }
  }

  /// Whether [alarm]'s ping was scheduled by another phone, whose backup
  /// this one was restored from.
  Future<bool> _pingBelongsToAnotherPhone(TransportAlarm alarm) async {
    final owner = alarm.pingDeviceId;
    if (owner == null) return false;
    final deviceId = await AppGroupStorage.deviceId();
    return deviceId != null && deviceId != owner;
  }

  Future<TransportAlarm?> _find(String alarmId) async =>
      (await _storage.loadAlarms()).where((a) => a.id == alarmId).firstOrNull;

  /// Schedules the alarm's first server ping and arms its watchdog. Returns
  /// the alarm with the new ping's ID and secret, or unchanged when there's
  /// no push token yet or the server refuses; [resyncPings] retries those.
  Future<TransportAlarm> _schedulePing(TransportAlarm alarm) async {
    // Server pings are iOS only.
    if (!Platform.isIOS) return alarm;
    final deviceToken = await ApnsTokenService.instance.getToken();
    if (deviceToken == null) return alarm; // no token yet
    final scheduledTime = _firstPingTime(alarm);

    final ping = await _server.schedule(deviceToken: deviceToken, scheduledTime: scheduledTime, requireAck: false);
    if (ping == null) return alarm;
    await PingWatchdogService.arm(alarm.id, scheduledTime);
    return alarm.copyWith(
      pingId: ping.id,
      pingSecret: ping.secret,
      pingDeviceId: await AppGroupStorage.deviceId(),
    );
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
      if (start.isAfter(now) && alarm.repeat.occursOn(day)) return start;
    }
    return now.add(const Duration(seconds: 10));
  }
}

/// Whether an alarm change worked, with the error to show if not.
class AlarmActionResult {
  final bool succeeded;
  final String? errorMessage;
  const AlarmActionResult.success() : succeeded = true, errorMessage = null;
  const AlarmActionResult.failure(this.errorMessage) : succeeded = false;
}
