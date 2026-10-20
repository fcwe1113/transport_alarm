import 'dart:io';

import 'package:flutter/services.dart';

/// The iOS local notification that tells the user an alarm's server pings
/// have stopped (Shared/PingWatchdog.swift). The notification extension moves
/// it on every ping; the app sets it for an alarm's first ping and removes it
/// when the alarm is turned off or deleted.
class PingWatchdogService {
  static const _channel = MethodChannel("com.fcwe1113.transport_alarm/ping_watchdog");

  static Future<void> arm(String alarmId, DateTime nextPingAt) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod("arm", {"alarmId": alarmId, "nextPingAt": nextPingAt.millisecondsSinceEpoch});
    } on PlatformException catch (_) {
      // The alarm still works without its watchdog.
    }
  }

  static Future<void> disarm(String alarmId) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod("disarm", {"alarmId": alarmId});
    } on PlatformException catch (_) {
      // Nothing to remove.
    }
  }
}
